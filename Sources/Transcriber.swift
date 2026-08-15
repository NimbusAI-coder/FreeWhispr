@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device transcription via Apple's SpeechAnalyzer (macOS 26+).
///
/// Audio is streamed into the analyzer as it is captured and never leaves the
/// machine: no network calls, no temp files, no API key. The language model
/// asset is downloaded once by the OS and lives in the system asset store.
@available(macOS 26.0, *)
actor Transcriber {

    enum TranscriberError: LocalizedError {
        case unavailable
        case unsupportedLocale(String)
        case modelNotReady(String)
        case modelRestoring(String)
        case modelRepairFailing(String, Int)
        case reservationFailed(String)
        case noCompatibleFormat

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "On-device speech recognition is unavailable on this Mac."
            case .unsupportedLocale(let id):
                return "Speech recognition does not support the locale \"\(id)\"."
            case .modelRestoring(let id):
                return """
                    The \(id) speech model was unloaded by macOS and is being \
                    restored in the background. This takes a few moments — try \
                    again shortly. No need to restart FreeWhispr.
                    """
            case .modelNotReady(let id):
                return """
                    The \(id) speech model is not installed yet. macOS downloads \
                    it on first use, which needs a network connection once. \
                    Check your connection and try again in a moment.
                    """
            case .modelRepairFailing(let id, let attempts):
                return """
                    Restoring the \(id) speech model has failed \(attempts) times \
                    in a row. This usually means no network connection or low disk \
                    space. FreeWhispr keeps retrying in the background; dictation \
                    will work again once a download succeeds.
                    """
            case .reservationFailed(let underlying):
                return """
                    macOS refused to allocate the speech model to FreeWhispr \
                    (\(underlying)). Try again; if this persists, relaunch the app.
                    """
            case .noCompatibleFormat:
                return "Could not negotiate an audio format with the speech analyzer."
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var collectTask: Task<String, Never>?

    /// Owns the input continuation and the format converter. Lives outside the
    /// actor so the audio thread can push buffers in order without awaiting.
    private let pipe = AudioPipe()

    /// Text finalized so far this session, plus the current volatile tail.
    private var finalizedText = ""

    /// Warms up the model so the first dictation is not slow. Safe to call
    /// repeatedly; the OS caches the installed asset.
    static func prewarm() async {
        guard SpeechTranscriber.isAvailable else { return }
        let locale = Locale(identifier: Settings.localeIdentifier)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        // Same ordering as `begin()`: without reserving first, the asset check
        // reports `.supported` forever and the model is never fetched.
        try? await Self.reserveTracked(locale: supported)
        Trace.write("prewarm: reserved \(supported.identifier), fetching model if needed")
        let state = try? await Self.ensureModelInstalled(for: [module], waitSeconds: 300)
        Trace.write("prewarm: done state=\(String(describing: state))")
    }

    /// Downloads the language asset if the system does not have it yet.
    /// Returns once the model is usable.
    /// Result of an asset check, kept distinct from "the locale is unsupported"
    /// so a model that is merely still downloading is not reported as a
    /// permanently broken language.
    enum ModelState {
        case ready
        case unsupported
        case notReady
    }

    /// - Parameter waitSeconds: how long to wait for an in-flight download.
    ///   Generous at launch, where nobody is blocked; near-zero when starting a
    ///   dictation, because audio capture does not begin until this returns and
    ///   a long wait presents as a dead recording overlay.
    /// Guards against stacking restores when several dictations fail in a row,
    /// and tracks whether restores are actually succeeding — a restore that
    /// fails forever must escalate, not loop behind an optimistic message.
    private static let restoreLock = NSLock()
    nonisolated(unsafe) private static var restoreInFlight = false
    nonisolated(unsafe) private static var consecutiveRestoreFailures = 0

    static func restoreFailureCount() -> Int {
        restoreLock.lock()
        defer { restoreLock.unlock() }
        return consecutiveRestoreFailures
    }

    /// One line for the menu bar when the model is in trouble, nil when healthy.
    static func healthWarning() -> String? {
        let failures = restoreFailureCount()
        guard failures > 0 else { return nil }
        return "⚠ Speech model download failing (\(failures)×) — check network"
    }

    /// Reserving is what allocates the asset to this app; without it the
    /// inventory never reports `.installed`. Failures used to be swallowed
    /// with `try?`, which turned "reservation limit reached" (the system
    /// allows 5) into an endless, misdiagnosed "restoring…" loop. Recover by
    /// releasing any reservation this app holds for *other* locales, retry
    /// once, and surface a real error if it still fails.
    private static func reserveTracked(locale: Locale) async throws {
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            Trace.write("reserve: threw \(error.localizedDescription) — releasing other locales and retrying")
            for held in await AssetInventory.reservedLocales where held.identifier != locale.identifier {
                _ = await AssetInventory.release(reservedLocale: held)
                Trace.write("reserve: released \(held.identifier)")
            }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch {
                Trace.write("reserve: retry FAILED: \(error.localizedDescription)")
                throw TranscriberError.reservationFailed(error.localizedDescription)
            }
        }
    }

    /// Re-downloads the asset off the hot path, so a lapsed model repairs
    /// itself without the user having to restart the app.
    private static func beginBackgroundRestore(locale: Locale) {
        restoreLock.lock()
        if restoreInFlight {
            restoreLock.unlock()
            return
        }
        restoreInFlight = true
        restoreLock.unlock()

        Task.detached(priority: .utility) {
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            try? await reserveTracked(locale: locale)
            let state = try? await ensureModelInstalled(for: [module], waitSeconds: 300)
            Trace.write("restore: finished state=\(String(describing: state))")
            noteRestoreOutcome(ready: state == .ready)
        }
    }

    /// Synchronous so the lock is never held from an async context.
    private static func noteRestoreOutcome(ready: Bool) {
        restoreLock.lock()
        if ready {
            consecutiveRestoreFailures = 0
        } else {
            consecutiveRestoreFailures += 1
        }
        restoreInFlight = false
        restoreLock.unlock()
    }

    /// Proactive watchdog. macOS may unload the speech asset at any time —
    /// after sleep, under disk pressure, or on its own schedule — and without
    /// this the user only finds out mid-dictation. Called periodically and on
    /// wake so a lapsed model is restored *before* the next dictation needs
    /// it. Silent when healthy; logs only when repair work actually happens.
    static func healthCheck(trigger: String) async {
        guard SpeechTranscriber.isAvailable else { return }
        let requested = Locale(identifier: Settings.localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        else { return }

        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [module]) == .installed { return }

        Trace.write("health(\(trigger)): model not installed — repairing")
        beginBackgroundRestore(locale: locale)
    }

    private static func ensureModelInstalled(
        for modules: [any SpeechModule],
        waitSeconds: TimeInterval
    ) async throws -> ModelState {
        var status = await AssetInventory.status(forModules: modules)
        if status == .installed { return .ready }
        if status == .unsupported { return .unsupported }

        // `.supported` means the language exists but its assets are not
        // downloaded for this app yet. A nil request means the system has
        // nothing queued, so there is no download to wait on.
        // Downloading can take minutes, so only ever do it off the hot path.
        if status == .supported, waitSeconds > 30 {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        }

        // A download kicked off by us or already in flight elsewhere reports
        // `.downloading`. Poll rather than treating that instant as failure.
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            status = await AssetInventory.status(forModules: modules)
            switch status {
            case .installed: return .ready
            case .unsupported: return .unsupported
            default: break
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        return .notReady
    }

    /// Builds the analyzer and starts consuming the input stream.
    func begin() async throws {
        await reset()
        finalizedText = ""

        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }

        Trace.write("begin: resolving locale")
        let requested = Locale(identifier: Settings.localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLocale(requested.identifier)
        }
        Trace.write("begin: locale=\(locale.identifier), reserving")

        // Progressive preset streams partial results while speaking, so the
        // final text is ready almost immediately after the key is released.
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        transcriber = module

        // Reserve before checking status: reservation is what allocates the
        // asset to this app, and `status(forModules:)` reports `.supported`
        // rather than `.installed` until that happens — even when the system
        // already lists the locale in `installedLocales`.
        try await Self.reserveTracked(locale: locale)

        // Short wait only. Recording cannot start until this returns, so a long
        // poll here shows up as an overlay that appears and hears nothing —
        // which is exactly what a 180s deadline here used to cause.
        switch try await Self.ensureModelInstalled(for: [module], waitSeconds: 4) {
        case .ready:
            break
        case .unsupported:
            throw TranscriberError.unsupportedLocale(locale.identifier)
        case .notReady:
            // The asset lapsed after launch. Only the long-wait path is allowed
            // to download, and that path previously ran just once at startup —
            // so every later dictation failed permanently and relaunching the
            // app was the only cure. Kick off a restore in the background so
            // the app heals itself instead of staying broken.
            let priorFailures = Self.restoreFailureCount()
            Trace.write("begin: model NOT ready — starting background restore (prior failures: \(priorFailures))")
            Self.beginBackgroundRestore(locale: locale)
            // "Try again shortly" is a lie once restores keep failing. After
            // two failed attempts, tell the user what is actually wrong.
            if priorFailures >= 2 {
                throw TranscriberError.modelRepairFailing(locale.identifier, priorFailures)
            }
            throw TranscriberError.modelRestoring(locale.identifier)
        }
        Trace.write("begin: model ready")

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        else { throw TranscriberError.noCompatibleFormat }

        let stream = pipe.open(target: format)

        let engine = SpeechAnalyzer(modules: [module])
        analyzer = engine

        // Drain results concurrently. The progressive preset emits volatile
        // partials that are later superseded by a final result covering the
        // same range, so only `isFinal` segments may be appended — appending
        // every result duplicates each word as it is being recognised.
        collectTask = Task { [weak self] in
            var assembled = ""
            do {
                for try await result in module.results {
                    guard result.isFinal else {
                        await self?.noteVolatile(String(result.text.characters))
                        continue
                    }
                    assembled += String(result.text.characters)
                    await self?.noteProgress(assembled)
                }
            } catch {
                // A cancelled or failed stream still yields whatever was
                // finalized before the failure.
            }
            return assembled
        }

        try await engine.prepareToAnalyze(in: format)
        try await engine.start(inputSequence: stream)
    }

    private func noteProgress(_ text: String) {
        finalizedText = text
    }

    /// The in-flight partial. Kept only so a caller could show live text; it is
    /// never appended to the transcript.
    private(set) var volatileText = ""

    private func noteVolatile(_ text: String) {
        volatileText = text
    }

    /// Feeds one captured buffer in, converting to the analyzer's format.
    ///
    /// This runs synchronously on the audio thread rather than hopping onto
    /// the actor. Spawning a Task per buffer would be simpler, but concurrent
    /// Tasks reach an actor in arbitrary order, which can scramble the audio
    /// timeline. `AudioPipe` is internally locked and yields in call order.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        pipe.feed(buffer)
    }

    /// Closes the input, waits for the analyzer to flush, returns the transcript.
    func finish() async -> String {
        pipe.close()

        let counts = pipe.counts

        var finalizeError = "none"
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                finalizeError = error.localizedDescription
                // A failed finalize can leave the results stream open forever,
                // which would wedge the collectTask await below. Force the
                // analyzer down so the stream is guaranteed to terminate.
                await analyzer.cancelAndFinishNow()
            }
        }

        let text = await collectTask?.value ?? finalizedText

        // The discriminator: volatile partials arriving while finals do not
        // means recognition worked and finalization is at fault. Neither
        // arriving means audio never reached the analyzer. Lengths only —
        // transcript content is never written to the trace.
        Trace.write(
            "finish: fed=\(counts.fed) yielded=\(counts.yielded) "
            + "finalChars=\(text.count) volatileChars=\(volatileText.count) "
            + "finalizeError=\(finalizeError)"
        )

        await reset()

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort transcript for stall recovery: everything finalized plus the
    /// current volatile tail. Only used when the normal finish path has already
    /// wedged — losing a few words beats losing the whole dictation.
    func snapshot() -> String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the session without producing text.
    func cancel() async {
        pipe.close()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        collectTask?.cancel()
        await reset()
    }

    private func reset() async {
        pipe.close()
        analyzer = nil
        transcriber = nil
        collectTask = nil
    }
}
