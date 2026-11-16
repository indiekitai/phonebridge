import Foundation

public enum ShotNaming {
    public static func safe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var out = ""
        var lastUnderscore = false
        for scalar in s.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_")
                lastUnderscore = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "device" : trimmed
    }

    /// `<device>[-d<display>]-<yyyyMMdd-HHmmss>.png`, with `-2`, `-3`... if the name is taken.
    public static func fileURL(in directory: URL, device: String, display: String?, date: Date = Date(),
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var base = safe(device)
        if let d = display, !d.isEmpty { base += "-d\(d)" }
        base += "-" + f.string(from: date)
        var url = directory.appendingPathComponent(base + ".png")
        var n = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        return url
    }
}
