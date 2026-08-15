import Foundation

/// Plain-file tracing for diagnosing dictation failures.
///
/// Deliberately not os_log: unified logging silently dropped everything this
/// app emitted, which is a bad property for the one tool you reach for when
/// something is already broken. A file always works and can just be read.
///
/// Only mechanical facts are recorded — device names, buffer counts, audio
/// levels, error text. Never transcript content.
enum Trace {

    static let url: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("FreeWhispr.log")
    }()

    private static let queue = DispatchQueue(label: "local.freewhispr.trace")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Keeps the file from growing without bound across sessions.
    static func rotateIfLarge() {
        queue.async {
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int,
                  size > 512_000 else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
