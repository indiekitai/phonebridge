import AppKit
import PhoneBridgeCore
import SwiftUI

enum DeviceRef: Hashable {
    case android(String)
    case ios(String)
}

struct IOSDevice: Hashable, Identifiable {
    let id: String      // AVCaptureDevice.uniqueID
    let name: String
}

enum SettingsKey {
    static let saveDirectory = "saveDirectory"
    static let copyToClipboard = "copyToClipboard"
    static let adbPath = "adbPath"
    static let maxEdge = "screenshotMaxEdge"
}

enum Defaults {
    static var saveDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/PhoneBridge").path
    }
    /// Long edge screenshots are shrunk to; 0 keeps the original.
    static var maxEdge: Int {
        UserDefaults.standard.object(forKey: SettingsKey.maxEdge) as? Int ?? Downscale.defaultMaxEdge
    }
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var android: [AndroidDevice] = []
    @Published private(set) var ios: [IOSDevice] = []
    @Published private(set) var displays: [String: [String]] = [:]
    @Published private(set) var adbPath: String?
    @Published private(set) var adbError: String?
    @Published var selection: DeviceRef?
    /// Last screenshot per device, so switching devices keeps the preview.
    @Published var lastShot: [DeviceRef: URL] = [:]

    let photos = IOSPhotoLibrary()
    private var timer: Timer?
    private var polling = false

    var adb: ADBClient? { adbPath.map(ADBClient.init(path:)) }

    /// Used by the self test so it never changes the user's saved setting.
    var saveDirectoryOverride: URL?

    var saveDirectory: URL {
        if let o = saveDirectoryOverride { return o }
        let p = UserDefaults.standard.string(forKey: SettingsKey.saveDirectory) ?? Defaults.saveDirectory
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    func start() {
        IOSCapture.enableScreenCaptureDevices()
        relocateADB()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func relocateADB() {
        let override = UserDefaults.standard.string(forKey: SettingsKey.adbPath)
        Task.detached {
            let path = ADBLocator.locate(override: override)
            await MainActor.run {
                self.adbPath = path
                self.adbError = path == nil ? ADBError.notFound.localizedDescription : nil
                self.displays = [:]
                self.refresh()
            }
        }
    }

    func refresh() {
        let iosNow = IOSCapture.currentDevices().map { IOSDevice(id: $0.uniqueID, name: DemoMode.isOn ? "iPhone" : $0.localizedName) }
        if iosNow != ios { ios = iosNow }

        guard let adb, !polling else { pruneSelection(); return }
        polling = true
        let known = displays
        Task.detached {
            var result: [AndroidDevice] = []
            var errMsg: String?
            var newDisplays: [String: [String]] = [:]
            do {
                result = try adb.devices()
                for d in result where d.isReady {
                    newDisplays[d.serial] = known[d.serial] ?? adb.displayIDs(serial: d.serial)
                }
            } catch {
                errMsg = error.localizedDescription
            }
            await MainActor.run {
                self.polling = false
                if result != self.android { self.android = result }
                if newDisplays != self.displays { self.displays = newDisplays }
                self.adbError = errMsg
                self.pruneSelection()
            }
        }
    }

    private func pruneSelection() {
        if let sel = selection {
            switch sel {
            case .android(let s) where !android.contains(where: { $0.serial == s }): selection = nil
            case .ios(let id) where !ios.contains(where: { $0.id == id }): selection = nil
            default: break
            }
        }
        if selection == nil {
            if let first = android.first(where: \.isReady) { selection = .android(first.serial) }
            else if let first = ios.first { selection = .ios(first.id) }
        }
    }

    func name(of ref: DeviceRef) -> String {
        switch ref {
        case .android(let s): return android.first { $0.serial == s }?.displayName ?? s
        case .ios(let id): return ios.first { $0.id == id }?.name ?? "iPhone"
        }
    }

    // MARK: Screenshot

    /// Takes a screenshot, saves it, optionally copies it. Returns the saved file.
    func screenshot(_ ref: DeviceRef, display: String?) async throws -> URL {
        let dir = saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw: Data
        switch ref {
        case .android(let serial):
            guard let adb else { throw ADBError.notFound }
            raw = try await Task.detached { try adb.screenshot(serial: serial, display: display) }.value
        case .ios(let id):
            raw = try await IOSCapture.screenshot(deviceID: id)
        }
        let maxEdge = Defaults.maxEdge
        let png = await Task.detached { Downscale.png(raw, maxEdge: maxEdge) }.value
        let url = ShotNaming.fileURL(in: dir, device: name(of: ref), display: display)
        try png.write(to: url)
        if UserDefaults.standard.object(forKey: SettingsKey.copyToClipboard) as? Bool ?? true {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = NSImage(data: png) { pb.writeObjects([image]) }
        }
        lastShot[ref] = url
        return url
    }
}
