import AVFoundation
import CoreImage
import CoreMediaIO
import ImageIO
import UniformTypeIdentifiers

/// iPhone screenshots through the macOS USB screen-capture channel (the one QuickTime uses).
/// No developer disk image, no sudo; the phone only needs to trust this Mac.
///
/// The "allow screen capture devices" switch stays on for the lifetime of the app: once the
/// process that turned it on exits, the iPhone takes several seconds to show up again.
/// A capture session is opened per screenshot and stopped right after the frame is taken,
/// so the phone is not left in "being recorded" mode.
enum IOSCapture {
    static func enableScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func currentDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                         position: .unspecified).devices
    }

    enum Failure: LocalizedError {
        case permissionDenied, deviceGone, noFrame, encode, open(String)
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有摄像头权限：系统设置 → 隐私与安全性 → 摄像头，打开 PhoneBridge。"
            case .deviceGone: return "iPhone 已断开，重新插上并在手机上点「信任」。"
            case .noFrame: return "10 秒没出画面：手机锁屏了，或还没信任这台 Mac。"
            case .encode: return "图片保存失败。"
            case .open(let m): return "打开设备失败：\(m)"
            }
        }
    }

    static func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
            throw Failure.permissionDenied
        default:
            throw Failure.permissionDenied
        }
    }

    /// Returns PNG data of the current screen.
    static func screenshot(deviceID: String) async throws -> Data {
        try await ensurePermission()
        guard let device = currentDevices().first(where: { $0.uniqueID == deviceID }) else { throw Failure.deviceGone }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try grab(device) })
            }
        }
    }

    private final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private var frames = 0
        private var taken = false
        let done = DispatchSemaphore(value: 0)
        var png: Data?

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            frames += 1
            if frames < 3 || taken { return }   // the first frames can be black
            taken = true
            defer { done.signal() }
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ci = CIImage(cvPixelBuffer: pb)
            guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
            let data = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dst, cg, nil)
            if CGImageDestinationFinalize(dst) { png = data as Data }
        }
    }

    private static func grab(_ device: AVCaptureDevice) throws -> Data {
        let session = AVCaptureSession()
        do { session.addInput(try AVCaptureDeviceInput(device: device)) }
        catch { throw Failure.open(error.localizedDescription) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let grabber = Grabber()
        output.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "phonebridge.ios.grab"))
        session.addOutput(output)
        session.startRunning()
        let result = grabber.done.wait(timeout: .now() + 10)
        session.stopRunning()
        if result == .timedOut { throw Failure.noFrame }
        guard let png = grabber.png else { throw Failure.encode }
        return png
    }
}
