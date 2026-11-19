import Foundation

/// A HarmonyOS NEXT / OpenHarmony device seen by `hdc`. Older Huawei phones (HarmonyOS 4 and
/// earlier) speak adb and show up as `AndroidDevice` instead.
public struct HarmonyDevice: Hashable, Sendable, Identifiable {
    public var id: String { key }
    /// hdc "connect key": the serial for USB, `ip:port` for network connections.
    public let key: String
    /// `USB` or `TCP`.
    public let connection: String
    /// `Connected`, `Offline`, `Unauthorized`, ...
    public let state: String

    public var isReady: Bool { state == "Connected" }
}

public enum HDCError: LocalizedError {
    case notFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "没找到 hdc。请安装 HarmonyOS Command Line Tools 或 DevEco Studio，或在设置里填写 hdc 路径。"
        case .failed(let m): return m
        }
    }
}

// MARK: - Pure helpers (unit tested)

public enum HDCParse {
    /// Parses `hdc list targets -v`: `<key>\t\t<USB|TCP>\t<state>\t<host>` per line, `[Empty]` when none.
    public static func targets(_ output: String) -> [HarmonyDevice] {
        var result: [HarmonyDevice] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("[") { continue }
            let parts = text.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }
            result.append(HarmonyDevice(key: parts[0], connection: parts[1], state: parts[2]))
        }
        return result
    }

    /// hdc exits 0 even when a command fails and prints `[Fail]...` (hdc itself) or
    /// `error: ...` (device tools) instead. Returns those lines, or nil if there are none.
    public static func failure(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("[Fail]") || $0.lowercased().hasPrefix("error") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `param get <key>` prints the value, or a failure line for unknown keys.
    public static func paramValue(_ output: String) -> String? {
        let v = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || failure(v) != nil || v.lowercased().contains("fail") { return nil }
        return v
    }
}

// MARK: - hdc location

public enum HDCLocator {
    /// Fixed install locations of DevEco Studio and the HarmonyOS Command Line Tools.
    public static let commonPaths = [
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
        "~/Library/Huawei/command-line-tools/sdk/default/openharmony/toolchains/hdc",
        "~/command-line-tools/sdk/default/openharmony/toolchains/hdc",
        "/opt/homebrew/bin/hdc",
        "/usr/local/bin/hdc",
    ]

    /// SDK roots with one sub folder per API level (`<root>/<api>/toolchains/hdc`).
    public static let versionedSDKRoots = [
        "~/Library/OpenHarmony/Sdk",
        "~/Library/Huawei/Sdk/openharmony",
    ]

    /// Same order as adb: user override, the login shell's PATH, then known install locations.
    public static func locate(override: String?) -> String? {
        let fm = FileManager.default
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let p = (o as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let r = try? runCommand(shell, ["-lc", "command -v hdc"], timeout: 8), r.status == 0 {
            let p = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if p.hasPrefix("/"), fm.isExecutableFile(atPath: p) { return p }
        }
        for c in commonPaths {
            let p = (c as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) { return p }
        }
        for root in versionedSDKRoots {
            let r = (root as NSString).expandingTildeInPath
            let versions = ((try? fm.contentsOfDirectory(atPath: r)) ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for v in versions {
                let p = "\(r)/\(v)/toolchains/hdc"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }
}

// MARK: - hdc client (blocking; call off the main thread)

/// Running hdc starts its server (port 8710) if none is running, like adb does.
/// Never runs `kill`, `start -r`, `tconn` or anything that changes connections. The only
/// device write is a temporary screenshot file in `/data/local/tmp`, removed right after.
public struct HDCClient: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    private func run(_ args: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try runCommand(path, args, timeout: timeout)
    }

    public func devices() throws -> [HarmonyDevice] {
        let r = try run(["list", "targets", "-v"], timeout: 10)
        let out = r.stdoutString
        if r.status != 0 { throw HDCError.failed(r.stderrString + out) }
        if let fail = HDCParse.failure(out) { throw HDCError.failed(fail) }
        return HDCParse.targets(out)
    }

    /// Marketing name such as "HUAWEI Mate 60", falling back to the model code.
    public func productName(key: String) -> String? {
        for param in ["const.product.name", "const.product.model"] {
            if let r = try? run(["-t", key, "shell", "param get \(param)"], timeout: 8),
               let v = HDCParse.paramValue(r.stdoutString) { return v }
        }
        return nil
    }

    /// Returns PNG data. Captures to a temp file on the device (hdc has no `exec-out`),
    /// pulls it into a temp folder on the Mac and removes both.
    public func screenshot(key: String) throws -> Data {
        let tag = UUID().uuidString.prefix(8)
        let localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonebridge-hdc-\(tag)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDir) }

        // PNG keeps small text sharp; older systems without `-t` fall back to the default JPEG.
        let attempts: [(ext: String, args: String)] = [("png", "-t png "), ("jpeg", "")]
        var lastError = "没有返回图片"
        for a in attempts {
            let remote = "/data/local/tmp/phonebridge-\(tag).\(a.ext)"
            defer { _ = try? run(["-t", key, "shell", "rm -f \(ShellQuote.quote(remote))"], timeout: 8) }
            let snap = try run(["-t", key, "shell", "snapshot_display \(a.args)-f \(ShellQuote.quote(remote))"], timeout: 20)
            guard snap.stdoutString.contains("success") else {
                lastError = HDCParse.failure(snap.stdoutString) ?? snap.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let local = localDir.appendingPathComponent("shot.\(a.ext)")
            let recv = try run(["-t", key, "file", "recv", remote, local.path], timeout: 30)
            // Exit status is 0 on failure too; trust only what actually arrived.
            if let data = try? Data(contentsOf: local), let png = Downscale.toPNG(data) { return png }
            lastError = HDCParse.failure(recv.stdoutString) ?? "拉取截图失败"
        }
        throw HDCError.failed("截图失败：\(lastError.isEmpty ? "没有返回图片" : lastError)")
    }
}
