import AppKit
import AVFoundation
import Foundation

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
                guard await self.ensureMicrophoneAccess() else {
                    self.fail("Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone.")
                    return
                }

                try await self.transcriber.begin()
                try self.capture.start()
                sound("Tink")
            } catch {
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

        capture.stop()

        // Ignore accidental taps that produced no meaningful audio.
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        guard duration > 0.35 else {
            Task { await transcriber.cancel() }
            overlay.hide()
            return
        }

        overlay.setStatus("Transcribing…")

        Task { @MainActor in
            let raw = await self.transcriber.finish()

            guard !raw.isEmpty else {
                self.overlay.hide()
                sound("Basso")
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
