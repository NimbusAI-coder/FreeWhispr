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
                    in a row. Causes: no network, low disk space, or a stale \
                    connection to the macOS speech service inside this process. \
                    FreeWhispr keeps retrying and will restart itself shortly if \
                    the failures continue — dictation returns automatically.
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
        } catch is CancellationError {
            // An abandoned begin() was cancelled mid-reserve; that is not a
            // reservation problem and must not be reported as one.
            throw CancellationError()
        } catch {
            Trace.write("reserve: threw \(error.localizedDescription) — releasing other locales and retrying")
            for held in await AssetInventory.reservedLocales where held.identifier != locale.identifier {
                _ = await AssetInventory.release(reservedLocale: held)
                Trace.write("reserve: released \(held.identifier)")
            }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch is CancellationError {
                throw CancellationError()
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

    /// Notified with the failure streak after each failed restore, so the app
    /// layer can escalate. Set once at launch.
    nonisolated(unsafe) static var onRestoreFailureStreak: (@Sendable (Int) -> Void)?

    /// Consecutive dictations that found the model missing. This is the *fast*
    /// stale-service signal: a background restore takes 300s to report failure,
    /// so waiting on that streak left the user pressing fn into a wall for
    /// fifteen minutes. Failed dictations arrive in seconds.
    nonisolated(unsafe) private static var consecutiveNotReady = 0

    private static func noteNotReady() -> Int {
        restoreLock.lock()
        consecutiveNotReady += 1
        let streak = consecutiveNotReady
        restoreLock.unlock()
        return streak
    }

    private static func noteModelReady() {
        restoreLock.lock()
        let had = consecutiveNotReady
        consecutiveNotReady = 0
        restoreLock.unlock()
        if had > 0 { Trace.write("model ready again after \(had) failed attempt(s)") }
    }

    /// Synchronous so the lock is never held from an async context.
    private static func noteRestoreOutcome(ready: Bool) {
        restoreLock.lock()
        if ready {
            consecutiveRestoreFailures = 0
        } else {
            consecutiveRestoreFailures += 1
        }
        let streak = consecutiveRestoreFailures
        restoreInFlight = false
        restoreLock.unlock()

        if !ready {
            onRestoreFailureStreak?(streak)
        }
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

        // Before believing "not installed", drop this process's retained model
        // state and ask again. The in-process view has been observed going
        // stale while the system's is healthy — a fresh process sees the same
        // model installed and downloadable in under a second. If releasing the
        // retention refreshes the view, this recovers instantly and no restart
        // is needed.
        await SpeechModels.endRetention()
        status = await AssetInventory.status(forModules: modules)
        if status == .installed {
            Trace.write("recovered: endRetention() refreshed a stale in-process model view")
            return .ready
        }

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

    // MARK: - Session identity
    //
    // This actor is reentrant: while one session's finish() is suspended in an
    // XPC call, a new session's begin() can walk in and mutate the shared
    // state underneath it. The controller's MainActor generation counter
    // cannot help — the damage happens on THIS actor, after suspension points
    // — so ownership is checked here, adjacent to the state it protects.
    // begin() mints an epoch and hands it to the controller; finish/cancel
    // take it back and no-op when it is stale, and begin() itself re-checks
    // after every await so an abandoned invocation can never clobber its
    // successor's pipe, analyzer, or collector.

    /// Identity of the session that currently owns the shared state.
    private var epoch = 0

    /// Throws if `my` no longer owns the actor state, or if the surrounding
    /// task was cancelled. Called after every await in begin().
    private func checkEpoch(_ my: Int) throws {
        guard my == epoch else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Builds the analyzer and starts consuming the input stream.
    /// Returns the session token; pass it to finish()/cancel() so a stale
    /// caller cannot tear down a newer session.
    func begin() async throws -> Int {
        epoch += 1
        let my = epoch

        // Take ownership. The shared slots are cleared synchronously — while
        // ownership is still certain — and only then is the captured old
        // analyzer awaited. Awaiting first opened a reentrancy window: this
        // invocation could wedge in the XPC call, be superseded by a newer
        // begin(), and then resume to wipe the LIVE session's collector and
        // text. The rule everywhere in this actor: never mutate shared state
        // after an await without re-proving ownership.
        pipe.close()
        let oldEngine = analyzer
        let oldCollector = collectTask
        analyzer = nil
        transcriber = nil
        collectTask = nil
        finalizedText = ""
        volatileText = ""
        oldCollector?.cancel()
        if let oldEngine {
            await oldEngine.cancelAndFinishNow()
        }
        try checkEpoch(my)

        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }

        Trace.write("begin: session \(my), resolving locale")
        let requested = Locale(identifier: Settings.localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLocale(requested.identifier)
        }
        try checkEpoch(my)
        Trace.write("begin: locale=\(locale.identifier), reserving")

        // Progressive preset streams partial results while speaking, so the
        // final text is ready almost immediately after the key is released.
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // Reserve before checking status: reservation is what allocates the
        // asset to this app, and `status(forModules:)` reports `.supported`
        // rather than `.installed` until that happens — even when the system
        // already lists the locale in `installedLocales`.
        try await Self.reserveTracked(locale: locale)
        try checkEpoch(my)

        // Short wait only. Recording cannot start until this returns, so a long
        // poll here shows up as an overlay that appears and hears nothing —
        // which is exactly what a 180s deadline here used to cause.
        switch try await Self.ensureModelInstalled(for: [module], waitSeconds: 4) {
        case .ready:
            Self.noteModelReady()
        case .unsupported:
            throw TranscriberError.unsupportedLocale(locale.identifier)
        case .notReady:
            // The asset lapsed after launch. Only the long-wait path is allowed
            // to download, and that path previously ran just once at startup —
            // so every later dictation failed permanently and relaunching the
            // app was the only cure. Kick off a restore in the background so
            // the app heals itself instead of staying broken.
            let priorFailures = Self.restoreFailureCount()
            let streak = Self.noteNotReady()
            Trace.write("begin: model NOT ready — starting background restore (failed dictations: \(streak), failed restores: \(priorFailures))")
            Self.beginBackgroundRestore(locale: locale)

            // The system disagreeing with us across several dictations in a
            // row is the stale-service signature: a fresh process sees the
            // model installed while this one cannot. Escalate on the fast
            // signal rather than waiting ~15 minutes for restore streaks.
            if streak >= 3 {
                Self.onRestoreFailureStreak?(streak)
                throw TranscriberError.modelRepairFailing(locale.identifier, streak)
            }
            if priorFailures >= 2 {
                throw TranscriberError.modelRepairFailing(locale.identifier, priorFailures)
            }
            throw TranscriberError.modelRestoring(locale.identifier)
        }
        try checkEpoch(my)
        Trace.write("begin: model ready")

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        else { throw TranscriberError.noCompatibleFormat }
        try checkEpoch(my)

        // Point of no return for shared state: everything below is fenced so a
        // superseded invocation cannot repoint the pipe or fields a newer
        // session now owns.
        let stream = pipe.open(target: format)
        transcriber = module

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
                        await self?.noteVolatile(String(result.text.characters), session: my)
                        continue
                    }
                    assembled += String(result.text.characters)
                    await self?.noteProgress(assembled, session: my)
                }
            } catch {
                // A cancelled or failed stream still yields whatever was
                // finalized before the failure.
            }
            return assembled
        }

        do {
            try await engine.prepareToAnalyze(in: format)
            try checkEpoch(my)
            try await engine.start(inputSequence: stream)
            try checkEpoch(my)
        } catch {
            // This invocation created these objects; if it cannot complete,
            // it cleans them up — but only if it still owns the shared slots.
            await engine.cancelAndFinishNow()
            resetIfCurrent(my)
            throw error
        }

        return my
    }

    private func noteProgress(_ text: String, session: Int) {
        guard session == epoch else { return }
        finalizedText = text
        // This final supersedes the partial that announced it; keeping the
        // partial would make snapshot() paste the tail twice.
        volatileText = ""
    }

    /// The in-flight partial. Kept only so a caller could show live text; it is
    /// never appended to the transcript.
    private(set) var volatileText = ""

    private func noteVolatile(_ text: String, session: Int) {
        guard session == epoch else { return }
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
    ///
    /// Everything this method needs is captured into locals before its first
    /// await: the actor is reentrant, so a newer session's begin() may reset
    /// the shared fields while finalize is suspended. The captured collector
    /// still yields this session's text even if the newer session cancelled it
    /// (a cancelled collector returns whatever it had assembled).
    func finish(session: Int) async -> String {
        guard session == epoch else {
            Trace.write("finish: session \(session) superseded before finish could run")
            return ""
        }

        let collector = collectTask
        let engine = analyzer
        let salvage = finalizedText
        pipe.close()

        let counts = pipe.counts

        var finalizeError = "none"
        if let engine {
            do {
                try await engine.finalizeAndFinishThroughEndOfInput()
            } catch {
                finalizeError = error.localizedDescription
                // A failed finalize can leave the results stream open forever,
                // which would wedge the collector await below. Force the
                // analyzer down so the stream is guaranteed to terminate.
                await engine.cancelAndFinishNow()
            }
        }

        var text = await collector?.value ?? salvage
        // A trailing final that arrived during finalize may have grown the
        // shared text past what the collector returned — but read it only if
        // this session still owns it.
        if session == epoch, finalizedText.count > text.count {
            text = finalizedText
        }

        // The discriminator: volatile partials arriving while finals do not
        // means recognition worked and finalization is at fault. Neither
        // arriving means audio never reached the analyzer. Lengths only —
        // transcript content is never written to the trace.
        Trace.write(
            "finish: session=\(session) fed=\(counts.fed) yielded=\(counts.yielded) "
            + "finalChars=\(text.count) volatileChars=\(volatileText.count) "
            + "finalizeError=\(finalizeError)"
        )

        resetIfCurrent(session)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Best-effort transcript for stall recovery: everything finalized plus the
    /// current volatile tail. Only used when the normal finish path has already
    /// wedged — losing a few words beats losing the whole dictation. Returns
    /// nothing for a superseded session so a stall can never paste a *newer*
    /// dictation's words as this one's.
    func snapshot(session: Int) -> String {
        guard session == epoch else { return "" }
        return (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the session without producing text. Stale callers — cleanup tasks
    /// left behind by an abandoned or superseded session — are ignored, so
    /// they can never tear down whichever session is live when they fire.
    func cancel(session: Int) async {
        guard session == epoch else {
            Trace.write("cancel: stale session \(session) ignored (current is \(epoch))")
            return
        }
        // Capture-then-clear before the await: a cancel suspended in the XPC
        // call used to resume after a newer begin() and kill the NEW session's
        // collector. Ownership is proven at entry, so clearing synchronously
        // and awaiting only captured locals is safe against any interleaving.
        pipe.close()
        let engine = analyzer
        let collector = collectTask
        resetIfCurrent(session)
        collector?.cancel()
        if let engine {
            await engine.cancelAndFinishNow()
        }
    }

    /// Clears the shared slots only when `session` still owns them.
    private func resetIfCurrent(_ session: Int) {
        guard session == epoch else { return }
        pipe.close()
        analyzer = nil
        transcriber = nil
        collectTask = nil
    }
}
