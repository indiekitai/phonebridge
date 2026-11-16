import Foundation

public struct AndroidDevice: Hashable, Sendable, Identifiable {
    public var id: String { serial }
    public let serial: String
    /// `device`, `unauthorized`, `offline`, ...
    public let state: String
    public let model: String

    public var isReady: Bool { state == "device" }
    public var displayName: String { model.isEmpty ? serial : model }
}

public struct RemoteEntry: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
}

public enum ADBError: LocalizedError {
    case notFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "没找到 adb。请安装 Android platform-tools，或在设置里填写 adb 路径。"
        case .failed(let m): return m
        }
    }
}

// MARK: - Pure helpers (unit tested)

public enum ADBParse {
    /// Parses `adb devices -l`.
    public static func devices(_ output: String) -> [AndroidDevice] {
        var result: [AndroidDevice] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("List of devices") || text.hasPrefix("*") { continue }
            let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            var model = ""
            for p in parts.dropFirst(2) where p.hasPrefix("model:") {
                model = String(p.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            result.append(AndroidDevice(serial: parts[0], state: parts[1], model: model))
        }
        return result
    }

    /// Parses `dumpsys SurfaceFlinger --display-id` into display ids.
    public static func displayIDs(_ output: String) -> [String] {
        var ids: [String] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("Display ") {
            let rest = line.dropFirst("Display ".count)
            let id = rest.prefix(while: \.isNumber)
            if !id.isEmpty { ids.append(String(id)) }
        }
        return ids
    }

    /// Parses lines produced by `stat -L -c '%F/%s/%Y/%n'` run inside `dir`.
    /// `/` cannot appear in a file name, so splitting on the first three slashes is safe
    /// for names containing spaces, quotes or non-ASCII characters.
    public static func statListing(_ output: String, directory: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let size = Int64(parts[1]), let mtime = TimeInterval(parts[2]) else { continue }
            let name = String(parts[3])
            if name == "." || name == ".." || name.isEmpty { continue }
            entries.append(RemoteEntry(
                name: name,
                path: RemotePath.join(directory, name),
                isDirectory: parts[0] == "directory",
                size: size,
                modified: Date(timeIntervalSince1970: mtime)))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// `screencap` on some ROMs prints warnings before the PNG; drop anything before the signature.
    public static func extractPNG(_ data: Data) -> Data? {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if data.starts(with: signature) { return data }
        guard let range = data.range(of: signature) else { return nil }
        return data.subdata(in: range.lowerBound..<data.endIndex)
    }
}

public enum ShellQuote {
    /// Quotes one argument for the device-side `sh`. `adb shell` re-parses its arguments,
    /// so every path that goes into a shell command must pass through here.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return "/" }
        let parent = String(p[..<idx])
        return parent.isEmpty ? "/" : parent
    }
}

// MARK: - adb location

public enum ADBLocator {
    public static let commonPaths = [
        "~/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
    ]

    /// GUI apps don't inherit the shell PATH. Resolve adb through the user's login shell first,
    /// so we pick the same binary as the terminal does; a different adb version would restart
    /// the running adb server and drop wireless connections.
    public static func locate(override: String?) -> String? {
        let fm = FileManager.default
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let p = (o as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let r = try? runCommand(shell, ["-lc", "command -v adb"], timeout: 8), r.status == 0 {
            let p = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if p.hasPrefix("/"), fm.isExecutableFile(atPath: p) { return p }
        }
        for c in commonPaths {
            let p = (c as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

// MARK: - adb client (blocking; call off the main thread)

/// Never runs `kill-server`, `connect`, `disconnect` or anything that writes outside the
/// paths the user explicitly picks.
public struct ADBClient: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    private func run(_ args: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runCommand(path, args, timeout: timeout)
    }

    public func devices() throws -> [AndroidDevice] {
        let r = try run(["devices", "-l"], timeout: 10)
        guard r.status == 0 else { throw ADBError.failed(r.stderrString) }
        return ADBParse.devices(r.stdoutString)
    }

    public func displayIDs(serial: String) -> [String] {
        guard let r = try? run(["-s", serial, "shell", "dumpsys SurfaceFlinger --display-id"], timeout: 8) else { return [] }
        return ADBParse.displayIDs(r.stdoutString)
    }

    public func screenshot(serial: String, display: String?) throws -> Data {
        var args = ["-s", serial, "exec-out", "screencap"]
        if let d = display, !d.isEmpty { args += ["-d", d] }
        args.append("-p")
        let r = try run(args, timeout: 20)
        guard let png = ADBParse.extractPNG(r.stdout) else {
            let msg = r.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.failed("截图失败：\(msg.isEmpty ? "没有返回图片" : msg)")
        }
        return png
    }

    public func list(serial: String, directory: String) throws -> [RemoteEntry] {
        let cmd = "cd \(ShellQuote.quote(directory)) && stat -L -c '%F/%s/%Y/%n' * .* 2>/dev/null"
        let r = try run(["-s", serial, "shell", cmd], timeout: 20)
        let text = r.stdoutString
        if r.status != 0 && text.isEmpty {
            // Distinguish "can't enter" from "empty directory".
            let probe = try run(["-s", serial, "shell", "cd \(ShellQuote.quote(directory)) && echo ok"], timeout: 10)
            if !probe.stdoutString.contains("ok") {
                throw ADBError.failed("打不开 \(directory)：\(probe.stdoutString + probe.stderrString)")
            }
        }
        return ADBParse.statListing(text, directory: directory)
    }

    /// `adb push`/`pull` use the sync protocol; remote paths are not shell-parsed there.
    public func push(serial: String, localPaths: [String], remoteDirectory: String) throws {
        let dest = remoteDirectory.hasSuffix("/") ? remoteDirectory : remoteDirectory + "/"
        let r = try run(["-s", serial, "push"] + localPaths + [dest], timeout: 600)
        guard r.status == 0 else { throw ADBError.failed("上传失败：\(r.stderrString + r.stdoutString)") }
    }

    public func pull(serial: String, remotePath: String, localDirectory: String) throws {
        let r = try run(["-s", serial, "pull", remotePath, localDirectory], timeout: 600)
        guard r.status == 0 else { throw ADBError.failed("下载失败：\(r.stderrString + r.stdoutString)") }
    }
}
