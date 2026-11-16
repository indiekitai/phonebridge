import AppKit
import AVFoundation
import CryptoKit
import PhoneBridgeCore

/// `open PhoneBridge.app --args --selftest <dir>` exercises the real app code paths
/// (adb lookup from a GUI launch, camera permission of the app bundle, screenshots of every
/// connected device, an Android push/pull round trip) and writes `report.txt` plus a
/// rendering of the main window into <dir>. The app quits when done.
///
/// The round trip only touches `/sdcard/Download/phonebridge-selftest/` and removes it after.
@MainActor
enum SelfTest {
    static var outputDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(store: DeviceStore, out: URL) async {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        store.saveDirectoryOverride = out.appendingPathComponent("shots", isDirectory: true)

        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        log("cameraAuthAtStart=\(["notDetermined", "restricted", "denied", "authorized"][auth.rawValue])")
        let t0 = Date()
        var firstPhotoChannel: Double?

        // Wait for discovery.
        for _ in 0..<20 where store.adbPath == nil || store.android.isEmpty || store.ios.isEmpty {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("adb=\(store.adbPath ?? "nil") error=\(store.adbError ?? "-")")
        log("android=\(store.android.map { "\($0.displayName)[\($0.state)] displays=\(store.displays[$0.serial] ?? [])" })")
        log(String(format: "ios=%@ photoChannels=%@ at %.1fs", "\(store.ios.map(\.name))", "\(store.photos.cameraNames)", Date().timeIntervalSince(t0)))

        // Real save directory (default is under Desktop, which may trigger a folder-access prompt).
        let real = UserDefaults.standard.string(forKey: SettingsKey.saveDirectory) ?? Defaults.saveDirectory
        do {
            let dir = URL(fileURLWithPath: (real as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".phonebridge-write-test")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            log("SAVEDIR OK \(real)")
        } catch {
            log("SAVEDIR FAIL \(real): \(error.localizedDescription)")
        }

        var refs: [(DeviceRef, String?)] = []
        for d in store.android where d.isReady {
            let ds = store.displays[d.serial] ?? []
            if ds.count > 1 { ds.forEach { refs.append((.android(d.serial), $0)) } } else { refs.append((.android(d.serial), nil)) }
        }
        for d in store.ios { refs.append((.ios(d.id), nil)); refs.append((.ios(d.id), nil)) }

        for (ref, display) in refs {
            let t0 = Date()
            do {
                let url = try await store.screenshot(ref, display: display)
                let size = NSImage(contentsOf: url).flatMap { $0.representations.first }.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "?"
                log(String(format: "SHOT OK %@ d=%@ %.2fs %@ %@", store.name(of: ref), display ?? "-",
                           Date().timeIntervalSince(t0), size, url.lastPathComponent))
            } catch {
                log("SHOT FAIL \(store.name(of: ref)) d=\(display ?? "-"): \(error.localizedDescription)")
            }
        }

        if let adb = store.adb {
            for d in store.android where d.isReady {
                log(await roundTrip(adb: adb, serial: d.serial, name: d.displayName, work: out))
            }
        }

        if let phone = store.ios.first {
            for _ in 0..<60 where !store.photos.hasCamera(named: phone.name) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if store.photos.hasCamera(named: phone.name) { firstPhotoChannel = Date().timeIntervalSince(t0) }
            log("photoChannels(after wait)=\(store.photos.cameraNames) seenAt=\(firstPhotoChannel.map { String(format: "%.1fs", $0) } ?? "never (30s)")")
            store.photos.open(name: phone.name)
            let openStart = Date()
            for _ in 0..<80 {
                if store.photos.status == .ready || store.photos.status == .locked { break }
                if case .failed = store.photos.status { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            var counts: [Int] = []
            while store.photos.status == .ready && Date().timeIntervalSince(openStart) < 40 {
                counts.append(store.photos.items.count)
                if counts.count >= 4 && Set(counts.suffix(4)).count == 1 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            log(String(format: "PHOTOS after %.1fs counts=%@", Date().timeIntervalSince(openStart), "\(counts)"))
            let df = ISO8601DateFormatter()
            log("PHOTOS top3=\(store.photos.items.prefix(3).map { "\($0.name)@\($0.date.map(df.string(from:)) ?? "nil")" }) nilDates=\(store.photos.items.filter { $0.date == nil }.count)")
            log("PHOTOS status=\(store.photos.status) items=\(store.photos.items.count) newest=\(store.photos.items.first?.name ?? "-")")
            if store.photos.status == .ready, let newest = store.photos.items.first {
                store.photos.requestThumbnail(newest)
                let dest = out.appendingPathComponent("photos", isDirectory: true)
                let result: Result<Int, Error> = await withCheckedContinuation { cont in
                    store.photos.download([newest], to: dest) { cont.resume(returning: $0) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let file = dest.appendingPathComponent(newest.name)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? -1
                switch result {
                case .success: log("PHOTO IMPORT \(size == newest.size ? "OK" : "SIZE MISMATCH") \(newest.name) expected=\(newest.size) got=\(size) thumbnail=\(store.photos.thumbnails[newest.id] != nil)")
                case .failure(let e): log("PHOTO IMPORT FAIL \(e.localizedDescription)")
                }
            }
            store.photos.close()
        }

        store.selection = refs.first?.0
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        snapshotWindow(to: out.appendingPathComponent("window.png"))
        log("window snapshot written")

        try? lines.joined(separator: "\n").appending("\n")
            .write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func roundTrip(adb: ADBClient, serial: String, name: String, work: URL) async -> String {
        let remoteDir = "/sdcard/Download/phonebridge-selftest"
        let fileName = "pb test 中文 it's.bin"
        let local = work.appendingPathComponent("up").appendingPathComponent(fileName)
        let back = work.appendingPathComponent("down-\(ShotNaming.safe(serial))")
        do {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            var bytes = [UInt8](repeating: 0, count: 300_000)
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
            try Data(bytes).write(to: local)
            return try await Task.detached { () throws -> String in
                _ = try runCommand(adb.path, ["-s", serial, "shell", "mkdir -p \(ShellQuote.quote(remoteDir))"])
                try adb.push(serial: serial, localPaths: [local.path], remoteDirectory: remoteDir)
                let listed = try adb.list(serial: serial, directory: remoteDir)
                try adb.pull(serial: serial, remotePath: RemotePath.join(remoteDir, fileName), localDirectory: back.path)
                _ = try runCommand(adb.path, ["-s", serial, "shell", "rm -r \(ShellQuote.quote(remoteDir))"])
                let a = SHA256.hash(data: try Data(contentsOf: local))
                let b = SHA256.hash(data: try Data(contentsOf: back.appendingPathComponent(fileName)))
                let ok = a == b && listed.contains { $0.name == fileName && $0.size == 300_000 }
                return "ROUNDTRIP \(ok ? "OK" : "MISMATCH") \(name) listed=\(listed.map { "\($0.name):\($0.size)" })"
            }.value
        } catch {
            return "ROUNDTRIP FAIL \(name): \(error.localizedDescription)"
        }
    }

    static func snapshotWindow(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
