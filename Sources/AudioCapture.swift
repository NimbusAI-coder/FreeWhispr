import AVFoundation
import Foundation

/// Pulls PCM buffers off the default input device and hands them to a callback.
/// Nothing is ever written to disk — buffers go straight to the on-device
/// transcriber and are released.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    /// Called on the audio thread. Keep the work here short.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Rough 0...1 input level, for the recording indicator.
    var onLevel: ((Float) -> Void)?

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start() throws {
        guard !engine.isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "FreeWhispr", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No usable audio input device."]
            )
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            if let level = Self.peakLevel(of: buffer) {
                self.onLevel?(level)
            }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }

    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var peak: Float = 0
        for sample in 0..<frames {
            peak = max(peak, abs(channels[0][sample]))
        }
        // Compress the range so quiet speech still moves the indicator.
        return min(1, peak * 3)
    }
}
