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
@available(macOS 26.0, *)
@MainActor
final class DictationController {

    private let capture = AudioCapture()
    private let transcriber = Transcriber()
    private let overlay = Overlay()

    private(set) var isRecording = false
    private var startedAt: Date?

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
    }

    // MARK: - Lifecycle

    func start(latched: Bool = false) {
        guard !isRecording else { return }

        isRecording = true
        startedAt = Date()
        onStateChange?(true)
        overlay.show(latched: latched)

        Task { @MainActor in
            do {
                let auth = AVCaptureDevice.authorizationStatus(for: .audio)
                Trace.write("start: micAuth=\(auth.rawValue) device=\(self.capture.inputDeviceName)")

                guard await self.ensureMicrophoneAccess() else {
                    Trace.write("start: microphone access denied")
                    self.fail("Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone.")
                    return
                }

                // Capture cannot start until setup finishes, so a stall here is
                // invisible to the user: the overlay sits there hearing nothing.
                // Bound it and report instead of hanging.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.transcriber.begin() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(8))
                        throw NSError(
                            domain: "FreeWhispr", code: 20,
                            userInfo: [NSLocalizedDescriptionKey: """
                                Timed out preparing the speech model. If macOS is \
                                still downloading it, wait a moment and try again.
                                """]
                        )
                    }
                    try await group.next()
                    group.cancelAll()
                }
                Trace.write("start: transcriber ready")

                try self.capture.start()
                let fmt = self.capture.inputFormat
                Trace.write("start: engine running rate=\(fmt.sampleRate) ch=\(fmt.channelCount)")

                sound("Tink")
                self.watchForDeadInput()
            } catch {
                Trace.write("start failed: \(error.localizedDescription)")
                self.fail(error.localizedDescription)
            }
        }
    }

    func setLatched(_ latched: Bool) {
        overlay.setLatched(latched)
    }

    func stopAndPaste() {
        guard isRecording else { return }
        isRecording = false
        onStateChange?(false)

        // Read the peak before stopping tears the session down.
        let peak = capture.sessionPeak
        let device = capture.inputDeviceName
        let buffers = capture.bufferCount
        capture.stop()

        // Ignore accidental taps that produced no meaningful audio.
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        Trace.write("stop: dur=\(String(format: "%.2f", duration))s buffers=\(buffers) peak=\(String(format: "%.5f", peak)) device=\(device)")

        guard duration > 0.35 else {
            Task { await transcriber.cancel() }
            overlay.hide()
            return
        }

        overlay.setStatus("Transcribing…")

        Task { @MainActor in
            let raw = await self.transcriber.finish()

            guard !raw.isEmpty else {
                // Nothing transcribed. Distinguish "the mic delivered pure
                // digital silence" — which means a revoked grant, a muted or
                // wrong input device, or a hardware mute switch — from "audio
                // arrived but held no speech". macOS reports a revoked
                // microphone by feeding zeroed buffers rather than failing, so
                // without this check both cases look identical to the user.
                if peak < AudioCapture.silenceThreshold {
                    self.fail("""
                        No audio reached \(device) — the level never moved. \
                        Check that FreeWhispr is enabled in System Settings › \
                        Privacy & Security › Microphone, that the right input \
                        device is selected in Sound settings, and that the mic \
                        is not muted.
                        """)
                } else {
                    self.overlay.hide()
                    sound("Basso")
                }
                return
            }

            var text = raw
            if Settings.cleanupEnabled {
                self.overlay.setStatus("Cleaning up…")
                if let cleaned = await OllamaCleanup.clean(raw) {
                    text = cleaned
                }
                // A nil result means Ollama was unavailable or returned
                // something unusable — the raw transcript stands.
            }

            self.overlay.hide()
            Paster.paste(text)
            sound("Pop")
        }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        startedAt = nil
        onStateChange?(false)
        capture.stop()
        Task { await transcriber.cancel() }
        overlay.hide()
        sound("Basso")
    }

    func toggle() {
        if isRecording { stopAndPaste() } else { start(latched: true) }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        isRecording = false
        startedAt = nil
        onStateChange?(false)
        capture.stop()
        Task { await transcriber.cancel() }
        overlay.hide()
        onError?(message)
        sound("Basso")
    }

    /// Flags a dead input mid-session, so a revoked microphone shows up while
    /// the overlay is on screen rather than as a silent no-op at the end.
    private func watchForDeadInput() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard self.isRecording else { return }
            guard self.capture.sessionPeak < AudioCapture.silenceThreshold else { return }
            self.overlay.setStatus("No audio — check mic access")
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
}
