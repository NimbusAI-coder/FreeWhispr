@preconcurrency import AVFoundation
import Foundation
import Speech

/// Bridges the audio thread to the speech analyzer's input stream.
///
/// Buffers arrive on a realtime audio callback and must reach the analyzer in
/// the order they were captured. An actor cannot guarantee that — separate
/// `Task`s awaiting the same actor are not FIFO — so this is a plain locked
/// class instead. `AsyncStream.Continuation.yield` is itself thread-safe and
/// order-preserving, so holding the lock only across conversion is enough.
@available(macOS 26.0, *)
final class AudioPipe: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var sourceFormat: AVAudioFormat?

    /// Diagnostics: buffers handed in, versus buffers that survived conversion
    /// and were actually yielded to the analyzer. A gap between these means
    /// audio is being dropped silently in `convertLocked`.
    private(set) var fedCount = 0
    private(set) var yieldedCount = 0
    var counts: (fed: Int, yielded: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (fedCount, yieldedCount)
    }

    /// Opens a fresh stream, discarding any previous one.
    func open(target: AVAudioFormat) -> AsyncStream<AnalyzerInput> {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        continuation?.finish()
        continuation = cont
        targetFormat = target
        converter = nil
        sourceFormat = nil
        fedCount = 0
        yieldedCount = 0
        lock.unlock()
        return stream
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        fedCount += 1
        guard let continuation, let target = targetFormat else { return }
        guard let converted = convertLocked(buffer, to: target) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
        yieldedCount += 1
    }

    func close() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        converter = nil
        targetFormat = nil
        sourceFormat = nil
        lock.unlock()
    }

    // MARK: - Conversion

    /// Caller must hold `lock`.
    private func convertLocked(
        _ buffer: AVAudioPCMBuffer,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }

        // Rebuild the converter if the input format changed (device switch).
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
