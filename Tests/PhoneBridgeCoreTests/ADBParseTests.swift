import XCTest
@testable import PhoneBridgeCore

final class ADBParseTests: XCTestCase {
    func testDevices() {
        let out = """
        List of devices attached
        ABC123                 device usb:2-1 product:foo model:SM_X210 device:bar transport_id:3
        10.0.0.5:5555          device product:p model:Tablet_A transport_id:4
        XYZ                    unauthorized usb:1-1 transport_id:7

        """
        let d = ADBParse.devices(out)
        XCTAssertEqual(d.map(\.serial), ["ABC123", "10.0.0.5:5555", "XYZ"])
        XCTAssertEqual(d[0].model, "SM X210")
        XCTAssertTrue(d[1].isReady)
        XCTAssertFalse(d[2].isReady)
        XCTAssertEqual(d[2].displayName, "XYZ")
    }

    func testDisplayIDs() {
        let out = """
        Display 0 (HWC display 0): no identification data
        Display 4630946984348363905 (HWC display 1): port=129 pnpId=QCM displayName=""
        """
        XCTAssertEqual(ADBParse.displayIDs(out), ["0", "4630946984348363905"])
    }

    func testStatListingHandlesSpacesQuotesAndUnicode() {
        let out = """
        directory/4096/1700000000/.
        directory/4096/1700000000/..
        regular file/12/1700000100/b file.txt
        directory/4096/1700000200/Download
        regular empty file/0/1700000300/it's 中文 名字.png
        symbolic link/9/1700000400/a/b
        garbage line
        """
        let e = ADBParse.statListing(out, directory: "/sdcard")
        XCTAssertEqual(e.map(\.name), ["Download", "a/b", "b file.txt", "it's 中文 名字.png"])
        XCTAssertTrue(e[0].isDirectory)
        XCTAssertEqual(e[2].path, "/sdcard/b file.txt")
        XCTAssertEqual(e[2].size, 12)
        XCTAssertEqual(e[3].path, "/sdcard/it's 中文 名字.png")
    }

    func testExtractPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        XCTAssertEqual(ADBParse.extractPNG(png), png)
        XCTAssertEqual(ADBParse.extractPNG(Data("WARNING: x\n".utf8) + png), png)
        XCTAssertNil(ADBParse.extractPNG(Data("error".utf8)))
    }

    func testShellQuoteRoundTripsThroughSh() throws {
        let names = ["plain", "with space", "it's", "中文 名字", "$(rm -rf x)", "a\"b", "back\\slash", "`tick`"]
        for name in names {
            let r = try runCommand("/bin/sh", ["-c", "printf %s \(ShellQuote.quote(name))"])
            XCTAssertEqual(r.stdoutString, name)
        }
    }

    func testRemotePath() {
        XCTAssertEqual(RemotePath.join("/sdcard", "a b"), "/sdcard/a b")
        XCTAssertEqual(RemotePath.join("/", "sdcard"), "/sdcard")
        XCTAssertEqual(RemotePath.parent("/sdcard/Download"), "/sdcard")
        XCTAssertEqual(RemotePath.parent("/sdcard/Download/"), "/sdcard")
        XCTAssertEqual(RemotePath.parent("/sdcard"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
    }

    func testShotNaming() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let date = Date(timeIntervalSince1970: 0)
        var taken: Set<String> = []
        let u1 = ShotNaming.fileURL(in: dir, device: "My Phone 13", display: nil, date: date) { taken.contains($0.lastPathComponent) }
        XCTAssertTrue(u1.lastPathComponent.hasPrefix("My_Phone_13-"))
        taken.insert(u1.lastPathComponent)
        let u2 = ShotNaming.fileURL(in: dir, device: "My Phone 13", display: nil, date: date) { taken.contains($0.lastPathComponent) }
        XCTAssertTrue(u2.lastPathComponent.hasSuffix("-2.png"))
        let u3 = ShotNaming.fileURL(in: dir, device: "Tab", display: "1", date: date) { _ in false }
        XCTAssertTrue(u3.lastPathComponent.hasPrefix("Tab-d1-"))
        XCTAssertEqual(ShotNaming.safe("杨 / x"), "杨_x")
        XCTAssertEqual(ShotNaming.safe("///"), "device")
    }
}
