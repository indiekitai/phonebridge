import Foundation

/// Appends diagnostic lines to ~/Library/Logs/PhoneBridge.log (kept under ~1 MB).
enum PBLog {
    private static let queue = DispatchQueue(label: "phonebridge.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PhoneBridge.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
