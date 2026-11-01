import Foundation
import AppKit

/// Always-on lightweight audit log for feature-completeness verification.
/// Appends to ~/Library/Application Support/GlassIsland/diag.log
enum DiagLog {
    private static let queue = DispatchQueue(label: "GlassIsland.DiagLog")
    private static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GlassIsland/diag.log")

    static func log(_ message: String) {
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    handle.write(data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
