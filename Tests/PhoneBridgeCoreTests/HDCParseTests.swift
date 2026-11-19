import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhoneBridgeCore

final class HDCParseTests: XCTestCase {
    func testTargetsRealUSBOutput() {
        // Captured from a Mate 60 (HarmonyOS NEXT) with hdc 3.1.0e.
        let out = "9CN0223907013063\t\tUSB\tConnected\tlocalhost\n"
        XCTAssertEqual(HDCParse.targets(out), [HarmonyDevice(key: "9CN0223907013063", connection: "USB", state: "Connected")])
        XCTAssertTrue(HDCParse.targets(out)[0].isReady)
    }

    func testTargetsEmptyAndMixedStates() {
        XCTAssertEqual(HDCParse.targets("[Empty]\n"), [])
        XCTAssertEqual(HDCParse.targets(""), [])
        let out = "192.168.1.8:5555\t\tTCP\tOffline\tlocalhost\nABC\t\tUSB\tUnauthorized\tlocalhost\n"
        let ds = HDCParse.targets(out)
        XCTAssertEqual(ds.map(\.key), ["192.168.1.8:5555", "ABC"])
        XCTAssertEqual(ds.map(\.connection), ["TCP", "USB"])
        XCTAssertFalse(ds.contains(where: \.isReady))
    }

    func testFailureLinesExitZero() {
        // Real outputs; hdc exits 0 for all of them.
        XCTAssertEqual(HDCParse.failure("[Fail]Not match target founded, check connect-key please\n"),
                       "[Fail]Not match target founded, check connect-key please")
        XCTAssertNotNil(HDCParse.failure("fileType: \nerror: fileName /nope/x.jpeg invalid, realpath nullptr!\n"))
        XCTAssertNil(HDCParse.failure("success: snapshot display 0 , write to /data/local/tmp/a.png as png, width: 1216, height: 2688\n"))
    }

    func testParamValue() {
        XCTAssertEqual(HDCParse.paramValue("HUAWEI Mate 60 \n"), "HUAWEI Mate 60")
        XCTAssertNil(HDCParse.paramValue(""))
        XCTAssertNil(HDCParse.paramValue("Get parameter \"x\" fail! errNum is:106!\n"))
    }

    func testToPNGTranscodesJPEG() throws {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let jpeg = NSMutableData()
        let dst = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))

        let png = try XCTUnwrap(Downscale.toPNG(jpeg as Data))
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(Downscale.pixelSize(png)?.width, 40)
        XCTAssertEqual(Downscale.toPNG(png), png)
        XCTAssertNil(Downscale.toPNG(Data("not an image".utf8)))
    }
}
