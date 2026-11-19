import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhoneBridgeCore

final class DownscaleTests: XCTestCase {
    private func makePNG(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        return out as Data
    }

    private func size(_ d: Data) -> [Int] {
        let s = Downscale.pixelSize(d)!
        return [s.width, s.height]
    }

    func testLandscapeTablet() {
        XCTAssertEqual(size(Downscale.png(makePNG(2000, 1314), maxEdge: 1000)), [1000, 657])
    }

    func testPortraitPhone() {
        XCTAssertEqual(size(Downscale.png(makePNG(1080, 2400), maxEdge: 1000)), [450, 1000])
    }

    func testSmallImageUntouched() {
        let d = makePNG(800, 600)
        XCTAssertEqual(Downscale.png(d, maxEdge: 1000), d)
    }

    func testZeroKeepsOriginal() {
        let d = makePNG(2000, 1314)
        XCTAssertEqual(Downscale.png(d, maxEdge: 0), d)
    }

    func testGarbageReturnedAsIs() {
        let d = Data("not an image".utf8)
        XCTAssertEqual(Downscale.png(d, maxEdge: 1000), d)
    }
}
