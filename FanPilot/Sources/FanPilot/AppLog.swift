import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "FanPilot.AppLog")
    private static let maxBytes: UInt64 = 1_000_000

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("FanPilot", isDirectory: true)
            .appendingPathComponent("fanpilot.log")
    }

    static func info(_ message: String) {
        write(level: "INFO", message)
    }

    static func warning(_ message: String) {
        write(level: "WARN", message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message)
    }

    private static func write(level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        queue.async {
            do {
                let url = fileURL
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                rotateIfNeeded(url)

                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: [.atomic])
                }
            } catch {
                NSLog("FanPilot file log failed: \(error)")
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
              size >= maxBytes else {
            return
        }

        let rotated = url.deletingLastPathComponent().appendingPathComponent("fanpilot.previous.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
