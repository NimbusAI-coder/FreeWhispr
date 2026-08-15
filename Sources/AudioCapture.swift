import AVFoundation
import Foundation

/// Pulls PCM buffers off the default input device and hands them to a callback.
/// Nothing is ever written to disk — buffers go straight to the on-device
/// transcriber and are released.
final class AudioCapture {
    /// Rebuilt for every session. A long-lived engine caches its binding to the
    /// input hardware, and neither `reset()` nor `stop()` re-establishes it — so
    /// after a device change or enough start/stop cycles the engine keeps
    /// running while delivering pure silence, with no error anywhere. A fresh
    /// instance re-resolves the current default input every time.
    private var engine = AVAudioEngine()
    private var tapInstalled = false

    /// Loudest sample seen since the last `start()`. The audio thread writes it
    /// and the main thread reads it after the session, so it is lock-guarded.
    private var peakLock = os_unfair_lock_s()
    private var _sessionPeak: Float = 0

    /// Highest input level observed during the session, 0 when the device
    /// delivered nothing but digital silence.
    var sessionPeak: Float {
        os_unfair_lock_lock(&peakLock)
        defer { os_unfair_lock_unlock(&peakLock) }
        return _sessionPeak
    }

    /// A revoked microphone grant is not reported as an error — macOS simply
    /// feeds the tap zero-filled buffers. Anything above this counts as real
    /// signal; room tone alone clears it comfortably.
    static let silenceThreshold: Float = 0.0005

    /// Number of buffers delivered by the tap this session. Zero means the tap
    /// never fired at all, which is a different fault from buffers of silence.
    private var _bufferCount = 0
    var bufferCount: Int {
        os_unfair_lock_lock(&peakLock)
        defer { os_unfair_lock_unlock(&peakLock) }
        return _bufferCount
    }

    /// Name of the device actually being recorded from, for error messages.
    var inputDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "the default input"
    }

    /// Called on the audio thread. Keep the work here short.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Rough 0...1 input level, for the recording indicator.
    var onLevel: ((Float) -> Void)?

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start() throws {
        guard !engine.isRunning else { return }

        os_unfair_lock_lock(&peakLock)
        _sessionPeak = 0
        _bufferCount = 0
        os_unfair_lock_unlock(&peakLock)

        // Discard the previous engine rather than reusing it; see the property
        // comment. Cheap to construct, and the only reliable way to pick up the
        // input device that is current *now*.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = AVAudioEngine()

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

            os_unfair_lock_lock(&self.peakLock)
            self._bufferCount += 1
            os_unfair_lock_unlock(&self.peakLock)

            if let raw = Self.rawPeak(of: buffer) {
                os_unfair_lock_lock(&self.peakLock)
                self._sessionPeak = max(self._sessionPeak, raw)
                os_unfair_lock_unlock(&self.peakLock)
                // Compress the range so quiet speech still moves the indicator.
                self.onLevel?(min(1, raw * 3))
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

    /// Uncompressed peak amplitude, 0...1.
    private static func rawPeak(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var peak: Float = 0
        for sample in 0..<frames {
            peak = max(peak, abs(channels[0][sample]))
        }
        return peak
    }
}
