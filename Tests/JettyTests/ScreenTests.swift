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

    func testScrollRegionParseCost() {
        func ms(cols: Int, rows: Int, top: Int, bot: Int, alt: Bool, cap: Int = 8, n: Int = 200_000) -> Double {
            let s = Screen(cols: cols, rows: rows, scrollbackCapRows: cap)
            if alt { s.switchScreenMode(1049, enabled: true) }
            s.decstbm(top: top, bot: bot)
            let p = Parser()
            p.screen = s
            var bytes = [UInt8]()
            bytes.reserveCapacity(n * 2)
            for _ in 0..<n {
                bytes.append(UInt8(ascii: "y"))
                bytes.append(0x0A)
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            p.feed(bytes)
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        let rows = 40
        let full = ms(cols: 80, rows: rows, top: 0, bot: rows - 1, alt: true)
        let bottom = ms(cols: 80, rows: rows, top: 0, bot: rows - 2, alt: true)
        let top = ms(cols: 80, rows: rows, top: 1, bot: rows - 1, alt: true)
        let small = ms(cols: 80, rows: rows, top: rows / 2, bot: rows - 1, alt: true)
        let primary = ms(cols: 105, rows: 35, top: 0, bot: 34, alt: false, cap: 50_000)
        func fullWidthMs() -> Double {
            let cols = 105, rows = 35, n = 10_000
            let s = Screen(cols: cols, rows: rows, scrollbackCapRows: 50_000)
            let p = Parser()
            p.screen = s
            var line = [UInt8](repeating: UInt8(ascii: "A"), count: cols)
            line.append(0x0A)
            var bytes = [UInt8]()
            bytes.reserveCapacity(n * line.count)
            for _ in 0..<n { bytes.append(contentsOf: line) }
            let t0 = ProcessInfo.processInfo.systemUptime
            p.feed(bytes)
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        let wide = fullWidthMs()
        fputs(String(format: "scroll parse ms full=%.1f bottom=%.1f top=%.1f small=%.1f primary=%.1f wide=%.1f\n",
                     full, bottom, top, small, primary, wide), stderr)
        fflush(stderr)
        XCTAssertLessThan(top / max(bottom, 0.1), 2.5, "top region parse should be near bottom region")
        XCTAssertLessThan(primary / max(full, 0.1), 3.0, "primary 50k sb parse should stay near alt")
    }

    func testScrollbackKeepsScrolledRows() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 4)
        s.printRun("AAAA")
        s.printRun("BBBB")
        s.printRun("CCCC")
        XCTAssertEqual(s.scrollbackCount, 1)
        XCTAssertEqual(s.historyRow(0)[0].contentPayload, UInt32(UInt8(ascii: "A")))
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "B")))
        XCTAssertEqual(s.glyph(0, 1), UInt32(UInt8(ascii: "C")))
        s.printRun("DDDD")
        XCTAssertEqual(s.scrollbackCount, 2)
        XCTAssertEqual(s.historyRow(0)[0].contentPayload, UInt32(UInt8(ascii: "A")))
        XCTAssertEqual(s.historyRow(1)[0].contentPayload, UInt32(UInt8(ascii: "B")))
        s.printRun("EEEE")
        s.printRun("FFFF")
        s.printRun("GGGG")
        XCTAssertEqual(s.scrollbackCount, 4)
        XCTAssertEqual(s.historyRow(0)[0].contentPayload, UInt32(UInt8(ascii: "B")))
        XCTAssertEqual(s.historyRow(3)[0].contentPayload, UInt32(UInt8(ascii: "E")))
        s.resize(cols: 6, rows: 2)
        XCTAssertEqual(s.scrollbackCount, 4)
        XCTAssertEqual(s.historyRow(0)[0].contentPayload, UInt32(UInt8(ascii: "B")))
        XCTAssertEqual(s.historyRow(0)[4].contentPayload, 0x20)
        s.ed(3)
        XCTAssertEqual(s.scrollbackCount, 0)
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "F")))
        XCTAssertEqual(s.glyph(0, 1), UInt32(UInt8(ascii: "G")))
    }

    func testCopyJoinsHistoryWrap() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 4)
        let p = Parser()
        p.screen = s
        p.feed("ABCDEFGHIJKL")
        XCTAssertEqual(s.scrollbackCount, 1)
        XCTAssertTrue(s.isHistoryWrapped(0))
        XCTAssertTrue(s.isWrapped(0))
        XCTAssertEqual(s.copySelection(x0: 0, y0: -1, x1: 3, y1: 0), "ABCDEFGH")
        XCTAssertEqual(s.copySelection(x0: 0, y0: -1, x1: 3, y1: 1), "ABCDEFGHIJKL")
    }

    func testLazyEraseUnreadRowIsBlank() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 4)
        s.printRun("AAAA")
        s.printRun("BBBB")
        s.index()
        XCTAssertEqual(s.historyRow(0).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "A")), count: 4))
        XCTAssertEqual(s.row(0).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "B")), count: 4))
        XCTAssertEqual(s.row(1).map(\.contentPayload),
                       Array(repeating: UInt32(0x20), count: 4))
    }

    func testWrapFillsEveryCellThenStealsIntact() {
        let cols = 4, rows = 3
        let s = Screen(cols: cols, rows: rows, scrollbackCapRows: 8)
        let p = Parser()
        p.screen = s
        var bytes = [UInt8]()
        for ch in [UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"),
                   UInt8(ascii: "D"), UInt8(ascii: "E")] {
            bytes += repeatElement(ch, count: cols)
        }
        p.feed(bytes)
        XCTAssertEqual(s.scrollbackCount, 2)
        XCTAssertEqual(s.historyRow(0).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "A")), count: cols))
        XCTAssertEqual(s.historyRow(1).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "B")), count: cols))
        XCTAssertEqual(s.row(0).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "C")), count: cols))
        XCTAssertEqual(s.row(1).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "D")), count: cols))
        XCTAssertEqual(s.row(2).map(\.contentPayload),
                       Array(repeating: UInt32(UInt8(ascii: "E")), count: cols))
        for y in 0..<rows {
            XCTAssertFalse(s.row(y).contains { $0.contentPayload == 0 })
        }
    }

    func testVtebenchFullscreenLFPayload() {
        let cols = 8, rows = 4
        let s = Screen(cols: cols, rows: rows, scrollbackCapRows: 16)
        let p = Parser()
        p.screen = s
        var bytes = [UInt8]()
        for ch in [UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"),
                   UInt8(ascii: "D"), UInt8(ascii: "E"), UInt8(ascii: "F")] {
            bytes += repeatElement(ch, count: cols)
            bytes.append(0x0A)
        }
        p.feed(bytes)
        func dump(_ cells: [Cell]) -> String {
            String(cells.map { c -> Character in
                let v = c.contentPayload
                if v == 0 { return "·" }
                if v == 0x20 { return " " }
                return Character(UnicodeScalar(v)!)
            })
        }
        XCTAssertEqual((0..<s.scrollbackCount).map { dump(s.historyRow($0)) }, [
            "AAAAAAAA",
            "       B",
            "BBBBBBB ",
            "       C",
            "CCCCCCC ",
            "       D",
            "DDDDDDD ",
            "       E",
        ])
        XCTAssertEqual((0..<rows).map { dump(s.row($0)) }, [
            "EEEEEEE ",
            "       F",
            "FFFFFFF ",
            "        ",
        ])
        XCTAssertEqual(s.cursorX, 7)
        XCTAssertEqual(s.cursorY, 3)
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

    func testRegionScrollKeepsRowsAboveSTBM() {
        let s = Screen(cols: 4, rows: 4, scrollbackCapRows: 0)
        s.printRun("AAAA")
        s.printRun("BBBB")
        s.printRun("CCCC")
        s.printRun("DDDD")
        s.decstbm(top: 1, bot: 3)
        s.cup(row: 3, col: 0)
        s.index()
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "A")))
        XCTAssertEqual(s.glyph(0, 1), UInt32(UInt8(ascii: "C")))
        XCTAssertEqual(s.glyph(0, 2), UInt32(UInt8(ascii: "D")))
        XCTAssertEqual(s.glyph(0, 3), UInt32(UInt8(ascii: " ")))
        s.index()
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "A")))
        XCTAssertEqual(s.glyph(0, 1), UInt32(UInt8(ascii: "D")))
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
        p.feed("\u{1B}[?1002;1006h")
        XCTAssertEqual(s.mouseEvent, 1002)
        XCTAssertTrue(s.mouseSgr)
        XCTAssertTrue(s.tracksMouse)
        p.feed("\u{1B}[?1000l")
        XCTAssertEqual(s.mouseEvent, 1002)
        p.feed("\u{1B}[?1002l")
        XCTAssertEqual(s.mouseEvent, 0)
        XCTAssertTrue(s.mouseSgr)
        XCTAssertFalse(s.tracksMouse)
        XCTAssertTrue(s.sendsAlternateScroll)
    }

    func testPrintRunPacksPenAndRemainders() {
        let lengths = [1, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 80, 105]
        for n in lengths {
            let cols = max(n, 2)
            let s = Screen(cols: cols, rows: 2, scrollbackCapRows: 0)
            s.penFG = PackedColor.indexed(9)
            s.penBG = PackedColor.rgb(r: 1, g: 2, b: 3)
            s.penAttrs = UInt16(ATTR_BOLD | UL_DOUBLE)
            s.implPtr.pointee.pen.extra = 0xBEEF
            var bytes = [UInt8](repeating: 0, count: n)
            for i in 0..<n { bytes[i] = 0x20 + UInt8(i % 0x5E) }
            bytes.withUnsafeBufferPointer { buf in
                guard let p = buf.baseAddress else { return }
                jt_scr_print_run(s.implPtr, p, buf.count)
            }
            let row = s.row(0)
            for x in 0..<n {
                let c = row[x]
                XCTAssertEqual(c.contentPayload, UInt32(bytes[x]), "n=\(n) x=\(x)")
                XCTAssertEqual(c.wide, 0, "n=\(n) x=\(x)")
                XCTAssertEqual(c.fg, PackedColor.indexed(9), "n=\(n) x=\(x)")
                XCTAssertEqual(c.bg, PackedColor.rgb(r: 1, g: 2, b: 3), "n=\(n) x=\(x)")
                XCTAssertEqual(c.attrs, UInt16(ATTR_BOLD | UL_DOUBLE), "n=\(n) x=\(x)")
                XCTAssertEqual(c.extra, 0xBEEF, "n=\(n) x=\(x)")
            }
            if n == cols {
                XCTAssertEqual(s.cursorX, cols - 1)
                XCTAssertTrue(s.pendingWrap)
            } else {
                XCTAssertEqual(s.cursorX, n)
                XCTAssertFalse(s.pendingWrap)
            }
        }
    }

    func testPrintRunWrapsMidRun() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        s.penFG = PackedColor.indexed(4)
        s.penAttrs = UInt16(ATTR_ITALIC)
        let bytes = Array("abcdefghijklmnopqrstuvwxyz".utf8)
        bytes.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            jt_scr_print_run(s.implPtr, p, buf.count)
        }
        XCTAssertEqual(s.plainString(), "abcdefghij\nklmnopqrst\nuvwxyz")
        XCTAssertTrue(s.isWrapped(0))
        XCTAssertTrue(s.isWrapped(1))
        XCTAssertFalse(s.isWrapped(2))
        XCTAssertEqual(s.row(1)[3].fg, PackedColor.indexed(4))
        XCTAssertEqual(s.row(1)[3].attrs, UInt16(ATTR_ITALIC))
        XCTAssertEqual(s.cursorY, 2)
        XCTAssertEqual(s.cursorX, 6)
    }

    func testPrintRunCost() {
        func minMs(_ trials: Int, _ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<trials {
                let t0 = ProcessInfo.processInfo.systemUptime
                body()
                best = min(best, (ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            return best
        }

        let isolated = minMs(5) {
            let cols = 256
            let s = Screen(cols: cols, rows: 2, scrollbackCapRows: 0)
            let line = [UInt8](repeating: UInt8(ascii: "Q"), count: cols)
            line.withUnsafeBufferPointer { buf in
                guard let p = buf.baseAddress else { return }
                for _ in 0..<40_000 {
                    jt_scr_cup(s.implPtr, 0, 0)
                    s.pendingWrap = false
                    jt_scr_print_run(s.implPtr, p, buf.count)
                }
            }
            XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "Q")))
        }

        func feedMs(cols: Int, rows: Int, cap: Int, alt: Bool, bytes: [UInt8]) -> Double {
            minMs(5) {
                let s = Screen(cols: cols, rows: rows, scrollbackCapRows: cap)
                if alt { s.switchScreenMode(1049, enabled: true) }
                let p = Parser()
                p.screen = s
                p.feed(bytes)
            }
        }

        var full = [UInt8](repeating: UInt8(ascii: "A"), count: 105)
        full.append(0x0A)
        var fullscreen = [UInt8]()
        fullscreen.reserveCapacity(1_048_576)
        while fullscreen.count < 1_048_576 { fullscreen.append(contentsOf: full) }

        var yn = [UInt8]()
        yn.reserveCapacity(1_048_576)
        while yn.count < 1_048_576 {
            yn.append(UInt8(ascii: "y"))
            yn.append(0x0A)
        }

        let wide = feedMs(cols: 105, rows: 35, cap: 50_000, alt: false, bytes: fullscreen)
        let ynAlt = feedMs(cols: 105, rows: 35, cap: 8, alt: true, bytes: yn)
        fputs(String(format: "print_run ms isolated=%.2f fullscreen1MiB=%.2f yn1MiB=%.2f\n",
                     isolated, wide, ynAlt), stderr)
        fflush(stderr)
        XCTAssertLessThan(isolated, 500)
    }

    func testTakeDirtyPrintSetsOnlyThatLogicalRow() {
        let s = Screen(cols: 8, rows: 24, scrollbackCapRows: 8)
        _ = takeDirty(s)
        s.cup(row: 10, col: 0)
        s.printRun("x")
        let (bits, _) = takeDirty(s)
        XCTAssertEqual(bits.count, 24)
        XCTAssertEqual(bits[10], 1)
        XCTAssertEqual(bits.filter { $0 != 0 }.count, 1)
        let (again, _) = takeDirty(s)
        XCTAssertTrue(again.allSatisfy { $0 == 0 })
    }

    func testTakeDirtyGathersViaRowmapAfterScroll() {
        let s = Screen(cols: 4, rows: 4, scrollbackCapRows: 4)
        s.printRun("AAAA")
        s.printRun("BBBB")
        s.printRun("CCCC")
        s.printRun("DDDD")
        s.printRun("EEEE")
        _ = takeDirty(s)
        s.cup(row: 0, col: 0)
        s.printRun("Z")
        let (bits, _) = takeDirty(s)
        XCTAssertEqual(bits[0], 1)
        XCTAssertEqual(bits.filter { $0 != 0 }.count, 1)
    }

    func testDamageGenIndexAtRegionBottomNotMidScreen() {
        let s = Screen(cols: 8, rows: 10, scrollbackCapRows: 8)
        let (_, gen0) = takeDirty(s)
        s.cup(row: 5, col: 0)
        s.index()
        let (_, genMid) = takeDirty(s)
        XCTAssertEqual(genMid, gen0)
        s.cup(row: 9, col: 0)
        s.index()
        let (_, genBot) = takeDirty(s)
        XCTAssertNotEqual(genBot, gen0)
    }

    func testDamageGenRegionBottomIndex() {
        let s = Screen(cols: 8, rows: 10, scrollbackCapRows: 8)
        s.decstbm(top: 0, bot: 4)
        let (_, gen0) = takeDirty(s)
        s.cup(row: 4, col: 0)
        s.index()
        let (_, gen1) = takeDirty(s)
        XCTAssertNotEqual(gen1, gen0)
        s.cup(row: 2, col: 0)
        s.index()
        let (_, gen2) = takeDirty(s)
        XCTAssertEqual(gen2, gen1)
    }

    func testDamageGenInsertDeleteLines() {
        let s = Screen(cols: 8, rows: 6, scrollbackCapRows: 0)
        let (_, gen0) = takeDirty(s)
        s.il(1)
        let (_, genIL) = takeDirty(s)
        XCTAssertNotEqual(genIL, gen0)
        s.dl(1)
        let (_, genDL) = takeDirty(s)
        XCTAssertNotEqual(genDL, genIL)
    }

    func testDamageGenAltIndexRotates() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 8)
        s.switchScreenMode(1049, enabled: true)
        let (_, gen0) = takeDirty(s)
        s.cup(row: 3, col: 0)
        s.index()
        let (_, gen1) = takeDirty(s)
        XCTAssertNotEqual(gen1, gen0)
    }

    private func takeDirty(_ s: Screen) -> (bits: [UInt8], gen: UInt32) {
        var bits = [UInt8](repeating: 0, count: s.rows)
        let gen = bits.withUnsafeMutableBufferPointer { buf in
            s.takeDirty(into: buf.baseAddress!, count: s.rows)
        }
        return (bits, gen)
    }
}
