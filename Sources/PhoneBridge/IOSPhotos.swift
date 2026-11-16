import AppKit
import ImageCaptureCore

/// iPhone photos and videos via ImageCaptureCore (same framework as the Image Capture app).
/// Read-only: lists the camera roll and copies selected items to the Mac.
@MainActor
final class IOSPhotoLibrary: NSObject, ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: ObjectIdentifier
        let name: String
        let date: Date?
        let size: Int64
        let isVideo: Bool
    }

    enum Status: Equatable {
        case idle, opening, locked, ready, failed(String)
    }

    @Published private(set) var cameraNames: [String] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var thumbnails: [ObjectIdentifier: NSImage] = [:]
    @Published private(set) var importing = false

    private let browser = ICDeviceBrowser()
    private var cameras: [ICCameraDevice] = []
    private var current: ICCameraDevice?
    private var files: [ObjectIdentifier: ICCameraFile] = [:]
    private var pendingDownloads = 0
    private var downloadErrors: [String] = []
    private var downloadDone: ((Result<Int, Error>) -> Void)?
    private var downloadedCount = 0
    private var emptyRetries = 0

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    private static func isApple(_ d: ICDevice) -> Bool {
        let kind = (d.productKind ?? "").lowercased()
        return kind.contains("iphone") || kind.contains("ipad") || kind.contains("ipod")
    }

    func hasCamera(named name: String) -> Bool { cameras.contains { $0.name == name } }

    func open(name: String) {
        guard let cam = cameras.first(where: { $0.name == name }) else {
            status = .failed(Self.replugHint)
            return
        }
        if current === cam, status == .ready || status == .opening { return }
        close()
        emptyRetries = 0
        current = cam
        cam.delegate = self
        status = .opening
        cam.requestOpenSession()
        // If the system photo service never answers, don't leave the user waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak cam] in
            guard let self, let cam, cam === self.current, self.status == .opening else { return }
            self.status = .failed(Self.replugHint)
        }
    }

    static let replugHint = "读不到这台 iPhone 的照片。请解锁手机；还不行就拔插一次数据线。"

    func close() {
        if let c = current, c.hasOpenSession { c.requestCloseSession() }
        current = nil
        items = []
        files = [:]
        thumbnails = [:]
        status = .idle
    }

    func requestThumbnail(_ item: Item) {
        guard thumbnails[item.id] == nil, let f = files[item.id] else { return }
        if let cg = f.thumbnail {
            thumbnails[item.id] = NSImage(cgImage: cg, size: .zero)
        } else {
            f.requestThumbnail()
        }
    }

    func download(_ selected: [Item], to directory: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let cam = current else { return }
        let targets = selected.compactMap { files[$0.id] }
        guard !targets.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        importing = true
        pendingDownloads = targets.count
        downloadedCount = 0
        downloadErrors = []
        downloadDone = completion
        for f in targets {
            cam.requestDownloadFile(f, options: [.downloadsDirectoryURL: directory], downloadDelegate: self,
                                    didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
                                    contextInfo: nil)
        }
    }

    private var reloadScheduled = false

    /// The catalog arrives in batches (tens of thousands of items on a big library); coalesce.
    private func scheduleReload(_ cam: ICCameraDevice) {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak cam] in
            guard let self else { return }
            self.reloadScheduled = false
            if let cam, cam === self.current, self.status == .ready { self.reloadCatalog(cam) }
        }
    }

    private func reloadCatalog(_ cam: ICCameraDevice) {
        let all = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var map: [ObjectIdentifier: ICCameraFile] = [:]
        var list: [Item] = []
        for f in all {
            let id = ObjectIdentifier(f)
            map[id] = f
            let uti = f.uti ?? ""
            list.append(Item(id: id, name: f.name ?? "?", date: f.creationDate, size: Int64(f.fileSize),
                             isVideo: uti.contains("movie") || uti.contains("video")))
        }
        // Right after another app (or a previous PhoneBridge) closed its session, the phone can
        // report a complete but empty catalog. Reopen a few times before believing it.
        if list.isEmpty && emptyRetries < 4 {
            emptyRetries += 1
            status = .opening
            if cam.hasOpenSession { cam.requestCloseSession() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak cam] in
                guard let self, let cam, cam === self.current else { return }
                cam.requestOpenSession()
            }
            return
        }
        files = map
        items = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        status = .ready
    }
}

extension IOSPhotoLibrary: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        onMain { [self] in
            guard let cam = device as? ICCameraDevice, Self.isApple(cam) else { return }
            cameras.append(cam)
            cameraNames = cameras.compactMap(\.name)
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        onMain { [self] in
            cameras.removeAll { $0 === device }
            cameraNames = cameras.compactMap(\.name)
            if current === device { close() }
        }
    }
}

extension IOSPhotoLibrary: ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        onMain { [self] in
            guard device === current, let error else { return }
            let ns = error as NSError
            // -9943: device locked. Wait for the access-restriction-removed callback.
            if ns.code == -9943 { status = .locked; return }
            // A session left over from a process that just quit is released within seconds; retry.
            if emptyRetries < 4, let cam = device as? ICCameraDevice {
                emptyRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak cam] in
                    guard let self, let cam, cam === self.current else { return }
                    cam.requestOpenSession()
                }
                return
            }
            status = .failed(error.localizedDescription)
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func didRemove(_ device: ICDevice) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { [self] in
            guard device === current else { return }
            reloadCatalog(device)
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        onMain { [self] in if device === current { status = .locked } }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        onMain { [self] in
            guard device === current, let cam = device as? ICCameraDevice else { return }
            status = .opening
            if cam.hasOpenSession { cam.requestCloseSession() }
            cam.requestOpenSession()
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        onMain { [self] in if camera === current, status == .ready { scheduleReload(camera) } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        onMain { [self] in if camera === current, status == .ready { scheduleReload(camera) } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        onMain { [self] in
            guard let thumbnail else { return }
            thumbnails[ObjectIdentifier(item)] = NSImage(cgImage: thumbnail, size: .zero)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    @objc nonisolated func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any] = [:], contextInfo: UnsafeMutableRawPointer?) {
        let message = error.map { "\(file.name ?? "?")：\($0.localizedDescription)" }
        onMain { [self] in
            if let message { downloadErrors.append(message) } else { downloadedCount += 1 }
            pendingDownloads -= 1
            guard pendingDownloads == 0 else { return }
            importing = false
            let done = downloadDone
            downloadDone = nil
            if downloadErrors.isEmpty {
                done?(.success(downloadedCount))
            } else {
                done?(.failure(NSError(domain: "PhoneBridge", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: downloadErrors.joined(separator: "\n")])))
            }
        }
    }
}

/// ImageCaptureCore normally calls back on the main thread; hop there if it ever doesn't.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
