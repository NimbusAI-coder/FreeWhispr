import AppKit
import AVFoundation
import Foundation

/// Session tracing goes to ~/Library/Logs/FreeWhispr.log — see Trace.swift.

/// Orchestrates one dictation: capture -> on-device transcribe -> optional
/// local cleanup -> paste.
///
/// Deliberately absent, compared with the app this was modelled on: no
/// screenshots, no window titles, no reading the focused app's selected text,
/// no bundle identifiers, no update checks, no telemetry. The only input is
/// the microphone, and the only output is a paste into the frontmost field.
///
/// Concurrency shape: everything here is MainActor. Each dictation gets a
/// `generation` number; every async continuation captures the generation it
/// was started under and re-checks it after awaiting, so work belonging to a
/// session that has since ended can never start the microphone, touch the
/// overlay, or raise an alert on behalf of a newer session. Without this, a
/// quick fn tap during setup left an orphaned task that started the audio
/// engine *after* the session ended — a hot mic that nothing ever stopped.
@available(macOS 26.0, *)
@MainActor
final class DictationController {

    private let capture = AudioCapture()
    private let transcriber = Transcriber()
    private let overlay = Overlay()

    private(set) var isRecording = false
    private var startedAt: Date?

    /// Incremented whenever a session starts or is torn down. Async work
    /// compares its captured value against this to detect that its session
    /// is over.
    private var generation = 0

    /// The in-flight setup for the current session, so teardown can cancel it.
    private var setupTask: Task<Void, Never>?

    /// Set by AppDelegate so the menu bar can reflect state.
    var onStateChange: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    init() {
        capture.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.transcriber.feed(buffer)
        }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.overlay.update(level: level) }
        }
        capture.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.captureConfigurationChanged() }
        }
    }

    private func isLive(_ gen: Int) -> Bool {
        isRecording && gen == generation
    }

    // MARK: - Lifecycle

    func start(latched: Bool = false) {
        guard !isRecording else { return }

        generation += 1
        let gen = generation
        isRecording = true
        startedAt = Date()
        onStateChange?(true)
        overlay.show(latched: latched)

        setupTask = Task { @MainActor in
            do {
                let auth = AVCaptureDevice.authorizationStatus(for: .audio)
                Trace.write("start: micAuth=\(auth.rawValue) device=\(self.capture.inputDeviceName)")

                guard await self.ensureMicrophoneAccess() else {
                    Trace.write("start: microphone access denied")
                    self.fail("Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone.", gen: gen)
                    return
                }
                guard self.isLive(gen) else {
                    await self.transcriber.cancel()
                    return
                }

                // Bound setup with a race, not a task group: a group waits for
                // its cancelled children before rethrowing, and the Speech
                // framework's XPC calls do not promise prompt cancellation —
                // so a group "timeout" could still hang for the whole stall.
                let beginTask = Task { try await self.transcriber.begin() }
                switch await Self.race(beginTask, seconds: 8) {
                case .success:
                    break
                case .failure(let error):
                    throw error
                case nil:
                    Trace.write("start: begin() STALLED past 8s — abandoning it")
                    beginTask.cancel()
                    // If the wedged call ever does return, tear down whatever
                    // half-built session it produced.
                    Task {
                        _ = try? await beginTask.value
                        await self.transcriber.cancel()
                    }
                    Task { await Transcriber.healthCheck(trigger: "begin-stall") }
                    throw NSError(
                        domain: "FreeWhispr", code: 20,
                        userInfo: [NSLocalizedDescriptionKey: """
                            Timed out preparing the speech model. It is being \
                            checked and repaired in the background — try again \
                            in a moment.
                            """]
                    )
                }
                Trace.write("start: transcriber ready")

                // The user may have released fn (or hit esc) while setup was
                // awaiting. Starting the mic now would leave it hot forever.
                guard self.isLive(gen) else {
                    Trace.write("start: session ended during setup — tearing down instead of starting the mic")
                    await self.transcriber.cancel()
                    return
                }

                try self.capture.start()
                let fmt = self.capture.inputFormat
                Trace.write("start: engine running rate=\(fmt.sampleRate) ch=\(fmt.channelCount)")

                sound("Tink")
                self.watchInput(gen: gen)
            } catch {
                Trace.write("start failed: \(error.localizedDescription)")
                self.fail(error.localizedDescription, gen: gen)
            }
        }
    }

    func setLatched(_ latched: Bool) {
        overlay.setLatched(latched)
    }

    func stopAndPaste() {
        guard isRecording else { return }
        let gen = generation
        isRecording = false
        onStateChange?(false)

        // Read diagnostics before stop() tears the session down.
        let engineRan = capture.didStart
        let peak = capture.sessionPeak
        let device = capture.inputDeviceName
        let buffers = capture.bufferCount
        capture.stop()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        guard engineRan else {
            // Setup never brought the engine up. The setup task owns this
            // outcome: on error it surfaces one correctly-diagnosed alert; on
            // a late success the generation guard makes it tear itself down.
            // Running the finish/silence diagnosis here raised a *second*
            // alert blaming the microphone for what was a model problem.
            Trace.write("stop: dur=\(String(format: "%.2f", duration))s ENGINE NEVER STARTED (setup owns the outcome)")
            overlay.hide()
            return
        }

        Trace.write("stop: dur=\(String(format: "%.2f", duration))s buffers=\(buffers) peak=\(String(format: "%.5f", peak)) device=\(device)")

        // Ignore accidental taps that produced no meaningful audio.
        guard duration > 0.35 else {
            Task { await transcriber.cancel() }
            overlay.hide()
            return
        }

        overlay.setStatus("Transcribing…")

        Task { @MainActor in
            // Bound the finish. finalizeAndFinishThroughEndOfInput is an XPC
            // call with no cancellation guarantee; unbounded, a wedged
            // analyzer left "Transcribing…" on screen forever with the
            // transcript silently lost.
            let finishTask = Task { await self.transcriber.finish() }
            var stalled = false
            var raw = await Self.race(finishTask, seconds: 10)
            if raw == nil {
                stalled = true
                let salvage = await self.transcriber.snapshot()
                Trace.write("finish: STALLED past 10s — salvaged \(salvage.count) chars, forcing shutdown")
                finishTask.cancel()
                Task { await self.transcriber.cancel() }
                Task { await Transcriber.healthCheck(trigger: "finish-stall") }
                raw = salvage
            }

            let text0 = raw ?? ""

            guard !text0.isEmpty else {
                guard gen == self.generation else { return }
                if stalled {
                    self.fail("""
                        Transcription stalled and no text could be recovered. \
                        The speech model may be reloading — it is being \
                        repaired in the background; try again in a moment.
                        """, gen: gen)
                } else if peak < AudioCapture.silenceThreshold {
                    // macOS reports a revoked microphone by feeding zeroed
                    // buffers rather than failing, so distinguish "the mic
                    // delivered digital silence" from "audio held no speech".
                    self.fail("""
                        No audio reached \(device) — the level never moved. \
                        Check that FreeWhispr is enabled in System Settings › \
                        Privacy & Security › Microphone, that the right input \
                        device is selected in Sound settings, and that the mic \
                        is not muted.
                        """, gen: gen)
                } else {
                    self.overlay.hide()
                    sound("Basso")
                }
                return
            }

            var text = text0
            if Settings.cleanupEnabled {
                if gen == self.generation { self.overlay.setStatus("Cleaning up…") }
                if let cleaned = await OllamaCleanup.clean(text0) {
                    text = cleaned
                }
                // A nil result means Ollama was unavailable or returned
                // something unusable — the raw transcript stands.
            }

            // If a new session started while we were finishing, its overlay is
            // on screen — never touch it. The user's words still get pasted;
            // losing them would be worse than a slightly odd insertion point.
            let live = (gen == self.generation)
            if live {
                self.overlay.hide()
            } else {
                Trace.write("finish: session superseded — pasting without touching the new session's UI")
            }
            Paster.paste(text)
            if live { sound("Pop") }
        }
    }

    func cancel() {
        guard isRecording else { return }
        teardown()
        sound("Basso")
    }

    func toggle() {
        if isRecording { stopAndPaste() } else { start(latched: true) }
    }

    // MARK: - Helpers

    /// Ends the current session and invalidates all of its in-flight work.
    private func teardown() {
        generation += 1
        setupTask?.cancel()
        setupTask = nil
        isRecording = false
        startedAt = nil
        onStateChange?(false)
        capture.stop()
        Task { await transcriber.cancel() }
        overlay.hide()
    }

    /// Surfaces one error for the session identified by `gen`. A failure
    /// arriving after its session already ended (or after another failure
    /// already fired) is logged and dropped — two racing failure paths must
    /// never stack two alert dialogs.
    private func fail(_ message: String, gen: Int) {
        guard gen == generation else {
            Trace.write("fail suppressed (stale session): \(message)")
            return
        }
        teardown()
        onError?(message)
        sound("Basso")
    }

    /// The input device changed mid-dictation (AirPods connected, display
    /// unplugged, …). The old engine is dead at that point — rebuild capture
    /// in place so the session survives; buffers keep flowing into the same
    /// pipe. If the rebuild fails, say so instead of recording silence.
    private func captureConfigurationChanged() {
        guard isRecording, capture.didStart else { return }
        Trace.write("capture: audio configuration changed mid-session — rebuilding engine")
        capture.stop()
        do {
            try capture.start()
        } catch {
            fail("""
                The input device changed mid-dictation and the microphone \
                could not be restarted: \(error.localizedDescription)
                """, gen: generation)
        }
    }

    /// Repeating dead-input watchdog. Warns on the overlay while the level
    /// stays at digital zero (revoked grant, muted mic) and clears the warning
    /// if audio starts flowing — so a dead mic is visible *during* the
    /// session, not as a surprise at the end.
    private func watchInput(gen: Int) {
        Task { @MainActor in
            var warned = false
            while self.isLive(gen) {
                try? await Task.sleep(for: .seconds(2))
                guard self.isLive(gen) else { return }
                let silent = self.capture.sessionPeak < AudioCapture.silenceThreshold
                if silent && !warned {
                    warned = true
                    self.overlay.setStatus("No audio — check mic access")
                } else if !silent && warned {
                    warned = false
                    self.overlay.setStatus("")
                }
            }
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func sound(_ name: String) {
        guard Settings.playSounds else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Timeout races

    /// Waits up to `seconds` for `task`; nil means it timed out. Unlike a task
    /// group, the loser is NOT awaited — a wedged framework call cannot hold
    /// the UI hostage. On timeout the caller owns cleanup of the still-running
    /// task.
    private static func race<T: Sendable>(
        _ task: Task<T, Error>, seconds: TimeInterval
    ) async -> Result<T, Error>? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
            let once = ResumeOnce()
            Task {
                let result: Result<T, Error>
                do { result = .success(try await task.value) } catch { result = .failure(error) }
                if once.claim() { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Non-throwing variant.
    private static func race<T: Sendable>(
        _ task: Task<T, Never>, seconds: TimeInterval
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce()
            Task {
                let value = await task.value
                if once.claim() { cont.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// First-caller-wins guard so a race's two arms cannot both resume the
    /// continuation.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
