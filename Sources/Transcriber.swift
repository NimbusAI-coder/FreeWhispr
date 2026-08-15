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
        case noCompatibleFormat

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "On-device speech recognition is unavailable on this Mac."
            case .unsupportedLocale(let id):
                return "Speech recognition does not support the locale \"\(id)\"."
            case .modelNotReady(let id):
                return """
                    The \(id) speech model is not installed yet. macOS downloads \
                    it on first use, which needs a network connection once. \
                    Check your connection and try again in a moment.
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
        _ = try? await AssetInventory.reserve(locale: supported)
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
        _ = try? await AssetInventory.reserve(locale: locale)

        // Short wait only. Recording cannot start until this returns, so a long
        // poll here shows up as an overlay that appears and hears nothing —
        // which is exactly what a 180s deadline here used to cause.
        switch try await Self.ensureModelInstalled(for: [module], waitSeconds: 4) {
        case .ready: break
        case .unsupported: throw TranscriberError.unsupportedLocale(locale.identifier)
        case .notReady: throw TranscriberError.modelNotReady(locale.identifier)
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
