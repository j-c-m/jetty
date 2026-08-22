import CVt
import XCTest
@testable import Jetty

final class ScreenTests: XCTestCase {
    func testEightiesBlackDefaults() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        XCTAssertEqual(s.paletteColor(0), RGB(r: 0x11, g: 0x11, b: 0x11))
        XCTAssertEqual(s.paletteColor(1), RGB(r: 0xEE, g: 0x45, b: 0x49))
        XCTAssertEqual(s.paletteColor(7), RGB(r: 0xCC, g: 0xCC, b: 0xCC))
        XCTAssertEqual(s.paletteColor(15), RGB(r: 0xF2, g: 0xF0, b: 0xEC))
        XCTAssertEqual(s.defaultFgRGB, RGB(r: 0xCC, g: 0xCC, b: 0xCC))
        XCTAssertEqual(s.defaultBgRGB, RGB(r: 0, g: 0, b: 0))
        XCTAssertNotEqual(s.defaultBgRGB, s.paletteColor(0))
        s.ed(2)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}c")
        XCTAssertEqual(s.defaultBgRGB, RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(s.paletteColor(0), RGB(r: 0x11, g: 0x11, b: 0x11))
    }

    func testPrintAndCursor() {
        let s = Screen(cols: 5, rows: 5, scrollbackCapRows: 8)
        s.printRun("1A")
        XCTAssertEqual(s.plainString(), "1A")
        XCTAssertEqual(s.cursorX, 2)
        XCTAssertEqual(s.cursorY, 0)
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "1")))
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "A")))
    }

    func testMode47PersistsAlt() {
        let s = Screen(cols: 5, rows: 5, scrollbackCapRows: 8)
        s.printRun("1A")
        s.switchScreenMode(47, enabled: true)
        XCTAssertTrue(s.inAlt)
        XCTAssertEqual(s.plainString(), "")
        XCTAssertEqual(s.cursorX, 2)
        s.printRun("2B")
        XCTAssertEqual(s.plainString(), "  2B")
        s.switchScreenMode(47, enabled: false)
        XCTAssertFalse(s.inAlt)
        XCTAssertEqual(s.plainString(), "1A")
        s.switchScreenMode(47, enabled: true)
        XCTAssertEqual(s.plainString(), "  2B")
    }

    func testMode1047ClearsAltOnLeave() {
        let s = Screen(cols: 5, rows: 5, scrollbackCapRows: 8)
        s.printRun("1A")
        s.switchScreenMode(1047, enabled: true)
        s.printRun("2B")
        XCTAssertEqual(s.plainString(), "  2B")
        s.switchScreenMode(1047, enabled: false)
        XCTAssertEqual(s.plainString(), "1A")
        s.switchScreenMode(1047, enabled: true)
        XCTAssertEqual(s.plainString(), "")
    }

    func testMode1049RestoresSavedAndCopiesCursor() {
        let s = Screen(cols: 5, rows: 5, scrollbackCapRows: 8)
        s.printRun("1A")
        s.switchScreenMode(1049, enabled: true)
        XCTAssertTrue(s.inAlt)
        XCTAssertEqual(s.plainString(), "")
        XCTAssertEqual(s.cursorX, 2)
        s.printRun("2B")
        XCTAssertEqual(s.plainString(), "  2B")
        s.switchScreenMode(1049, enabled: false)
        XCTAssertFalse(s.inAlt)
        XCTAssertEqual(s.plainString(), "1A")
        XCTAssertEqual(s.cursorX, 2)
        XCTAssertEqual(s.cursorY, 0)
    }

    func testMode47CopiesCursorFromCUP() {
        let s = Screen(cols: 80, rows: 25, scrollbackCapRows: 8)
        s.cup(row: 9, col: 39)
        s.switchScreenMode(47, enabled: true)
        XCTAssertEqual(s.cursorY, 9)
        XCTAssertEqual(s.cursorX, 39)
    }

    func testXenlSetsWrap() {
        let s = Screen(cols: 4, rows: 3, scrollbackCapRows: 8)
        s.printRun("abcd")
        XCTAssertTrue(s.pendingWrap)
        XCTAssertFalse(s.isWrapped(0))
        s.printRun("e")
        XCTAssertTrue(s.isWrapped(0))
        XCTAssertEqual(s.cursorY, 1)
        XCTAssertEqual(s.cursorX, 1)
        XCTAssertEqual(s.glyph(0, 1), UInt32(UInt8(ascii: "e")))
    }

    func testED3ClearsHistoryKeepsLive() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 10)
        s.printRun("aaaa")
        s.printRun("bbbb")
        s.printRun("c")
        XCTAssertGreaterThan(s.scrollbackCount, 0)
        let live = s.plainString()
        s.ed(3)
        XCTAssertEqual(s.scrollbackCount, 0)
        XCTAssertEqual(s.plainString(), live)
    }

    func testIRMShifts() {
        let s = Screen(cols: 6, rows: 2, scrollbackCapRows: 0)
        s.printRun("XXXX")
        s.cup(row: 0, col: 0)
        s.insertMode = true
        s.printRun("AB")
        XCTAssertEqual(s.plainString(), "ABXXXX")
    }

    func testIndexAtRegionEdgeVsBelow() {
        let s = Screen(cols: 8, rows: 10, scrollbackCapRows: 20)
        s.decstbm(top: 0, bot: 4)
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 0)
        s.cup(row: 9, col: 0)
        XCTAssertEqual(s.cursorY, 9)
        let before = s.scrollbackCount
        s.index()
        XCTAssertEqual(s.cursorY, 9)
        XCTAssertEqual(s.scrollbackCount, before)
        s.cup(row: 4, col: 0)
        s.index()
        XCTAssertEqual(s.cursorY, 4)
        XCTAssertEqual(s.scrollbackCount, before + 1)
    }

    func testResizeFloor() {
        let s = Screen(cols: 80, rows: 24, scrollbackCapRows: 4)
        s.resize(cols: 1, rows: 1)
        XCTAssertEqual(s.cols, 2)
        XCTAssertEqual(s.rows, 1)
    }

    func testICHSplitsWidePair() {
        let s = Screen(cols: 6, rows: 2, scrollbackCapRows: 0)
        s.printRun("abcdef")
        let row = jt_scr_row(s.implPtr, 0)!
        row[1].content = content_scalar(0x4E00, WIDE_FULL)
        row[2].content = content_scalar(0, WIDE_TAIL)
        s.cup(row: 0, col: 2)
        s.ich(1)
        let after = s.row(0)
        XCTAssertNotEqual(after[1].wide, WIDE_FULL)
        XCTAssertNotEqual(after[2].wide, WIDE_TAIL)
    }

    func testDCHSplitsWidePair() {
        let s = Screen(cols: 6, rows: 2, scrollbackCapRows: 0)
        s.printRun("abcdef")
        let row = jt_scr_row(s.implPtr, 0)!
        row[1].content = content_scalar(0x4E00, WIDE_FULL)
        row[2].content = content_scalar(0, WIDE_TAIL)
        s.cup(row: 0, col: 2)
        s.dch(1)
        let after = s.row(0)
        XCTAssertNotEqual(after[1].wide, WIDE_FULL)
    }

    func testAltDoesNotGrowScrollback() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 10)
        s.printRun("aaaa")
        s.printRun("bbbb")
        s.printRun("cccc")
        let before = s.scrollbackCount
        let produced = s.linesScrolled
        XCTAssertGreaterThan(before, 0)
        XCTAssertFalse(s.sendsAlternateScroll)
        s.switchScreenMode(1049, enabled: true)
        XCTAssertTrue(s.inAlt)
        XCTAssertTrue(s.sendsAlternateScroll)
        XCTAssertEqual(s.viewportHistoryCount, 0)
        XCTAssertEqual(s.scrollbackCount, before)
        s.printRun("xxxx")
        s.printRun("yyyy")
        s.printRun("zzzz")
        XCTAssertEqual(s.scrollbackCount, before)
        XCTAssertEqual(s.linesScrolled, produced)
        s.switchScreenMode(1049, enabled: false)
        XCTAssertFalse(s.inAlt)
        XCTAssertEqual(s.scrollbackCount, before)
        XCTAssertEqual(s.viewportHistoryCount, before)
        s.printRun("dddd")
        XCTAssertEqual(s.scrollbackCount, before + 1)
    }

    func testBlitOnAltIsLiveNotHistory() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 10)
        s.printRun("AAAA")
        s.printRun("BBBB")
        s.printRun("CCCC")
        s.switchScreenMode(1049, enabled: true)
        s.cup(row: 0, col: 0)
        s.printRun("XY")
        var dest = [Cell](repeating: .empty, count: 4)
        var blank = Cell.empty
        blank.content = content_scalar(0x20, WIDE_NARROW)
        dest.withUnsafeMutableBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            s.blitDocumentRow(0, to: p, destCols: 4, liveRows: 2, blank: blank)
        }
        XCTAssertEqual(dest[0].contentPayload, UInt32(UInt8(ascii: "X")))
        XCTAssertEqual(dest[1].contentPayload, UInt32(UInt8(ascii: "Y")))
    }

    func testAlternateScrollRequiresAltAnd1007AndNoMouse() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 8)
        let p = Parser()
        p.screen = s
        XCTAssertTrue(s.mouseAltScroll)
        XCTAssertFalse(s.sendsAlternateScroll)
        p.feed("\u{1B}[?1049h")
        XCTAssertTrue(s.sendsAlternateScroll)
        p.feed("\u{1B}[?1007l")
        XCTAssertFalse(s.mouseAltScroll)
        XCTAssertFalse(s.sendsAlternateScroll)
        p.feed("\u{1B}[?1007h")
        XCTAssertTrue(s.sendsAlternateScroll)
        p.feed("\u{1B}[?1000h")
        XCTAssertEqual(s.mouseEvent, 1000)
        XCTAssertFalse(s.sendsAlternateScroll)
    }
}
