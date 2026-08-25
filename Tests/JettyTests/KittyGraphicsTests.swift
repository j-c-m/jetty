import CVt
import XCTest
@testable import Jetty

final class KittyGraphicsTests: XCTestCase {
    private func apc(_ body: String) -> String {
        "\u{1B}_G\(body)\u{1B}\\"
    }

    private func b64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    func testCellStill16() {
        XCTAssertEqual(MemoryLayout<CVt.Cell>.size, 16)
    }

    func testNonGApcDoesNotPrintOrReply() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}_hello\u{1B}\\X")
        XCTAssertEqual(s.plainString(), "X")
        XCTAssertEqual(p.writes, [])
    }

    func testQueryThenDA1() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;\(b64([255, 0, 0]))"))
        p.feed("\u{1B}[c")
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertTrue(out.contains("\u{1B}[?1;2c"), out)
        XCTAssertTrue(out.hasPrefix("\u{1B}_G"), out)
        XCTAssertLessThan(out.firstIndex(of: "c") ?? out.endIndex, out.endIndex)
        let okAt = out.range(of: "OK")?.lowerBound
        let daAt = out.range(of: "[?1;2c")?.lowerBound
        XCTAssertNotNil(okAt)
        XCTAssertNotNil(daAt)
        if let okAt, let daAt {
            XCTAssertLessThan(okAt, daAt)
        }
    }

    func testGraphicsOffNoQueryReply() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setKittyGraphics(false)
        let p = Parser()
        p.screen = s
        p.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;\(b64([255, 0, 0]))"))
        p.feed("\u{1B}[c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1;2c")
    }

    func testCursorMovesToRightOfLastRow() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 3, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=3,r=4,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 3)
        XCTAssertEqual(s.cursorY, 3)
        XCTAssertFalse(s.pendingWrap)
    }

    func testFullWidthPutWrapsToLineAfterImage() {
        let s = Screen(cols: 10, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 4, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=10,r=3,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 3)
    }

    func testTallPutAtBottomScrollsPromptBelow() {
        let s = Screen(cols: 10, rows: 5, scrollbackCapRows: 32)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[5;1H")
        XCTAssertEqual(s.cursorY, 4)
        let rgb = [UInt8](repeating: 5, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=10,r=8,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 4)
        XCTAssertGreaterThan(s.scrollbackCount, 0)
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
    }

    func testC1LeavesCursor() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[3;5H")
        let rgb = [UInt8](repeating: 6, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=4,r=3,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 4)
        XCTAssertEqual(s.cursorY, 2)
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testImplicitIdDoesNotReply() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(p.writes, [])
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testImageNumberRepliesAssignedId() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,I=13,t=d,C=1;\(b64(rgb))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("I=13"), out)
        XCTAssertTrue(out.contains("i="), out)
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertFalse(out.contains("i=13;"), out)
    }

    func testRGBPutDoesNotFillCells() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        var rgb = [UInt8](repeating: 0, count: 12)
        rgb[0] = 255
        p.feed(apc("a=T,f=24,s=2,v=2,i=7,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        XCTAssertEqual(s.imgHistN, 0)
        XCTAssertEqual(s.plainString().trimmingCharacters(in: .whitespacesAndNewlines), "")
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("i=7"), out)
        XCTAssertTrue(out.contains("OK"), out)
    }

    func testRetransmitDropsOldPlacement() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 128, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=3,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=t,f=24,s=2,v=2,i=3,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testIndexMovesToHistoryWithoutWalkingIdle() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 1, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=9,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        for _ in 0..<8 {
            p.feed("\n")
        }
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
        p.feed(String(repeating: "y\n", count: 200))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
    }

    func testED2ClearsLiveDest() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[7;1H")
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=4,r=10,t=d,C=1;\(b64(rgb))"))
        XCTAssertGreaterThan(s.imgLiveN, 0)
        p.feed("\n\n")
        p.feed("\u{1B}[2J")
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testQuietSuppressesOK() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 2, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=5,q=1,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(p.writes, [])
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testU1ENOTSUP() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,U=1,i=1,s=1,v=1,f=24,t=d;\(b64([1, 2, 3]))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("ENOTSUP"), out)
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testPasswdFileRefused() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        let path = Array("/etc/passwd".utf8)
        p.feed(apc("a=t,f=24,s=1,v=1,i=8,t=f;\(b64(path))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL") || out.contains("ENOENT") || !out.contains("OK") || out.contains("EINVAL"), out)
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testPNG1x1() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let png = Self.png1x1Red
        p.feed(apc("a=T,f=100,i=11,t=d,C=1;\(b64(png))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testChunkedRGB() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 7, count: 12)
        let enc = b64(rgb)
        let mid = enc.index(enc.startIndex, offsetBy: 8)
        p.feed(apc("a=T,f=24,s=2,v=2,i=12,t=d,m=1,C=1;\(enc[..<mid])"))
        XCTAssertEqual(s.imgLiveN, 0)
        p.feed(apc("m=0;\(enc[mid...])"))
        XCTAssertEqual(s.imgLiveN, 1)
    }

    /// 1×1 opaque red PNG.
    private static let png1x1Red: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE,
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    ]
}
