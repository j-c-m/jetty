import CVt
import XCTest
@testable import Jetty

final class ParserTests: XCTestCase {
    func testASCIIRun() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("hello")
        XCTAssertEqual(s.plainString(), "hello")
        XCTAssertEqual(s.cursorX, 5)
    }

    func testWrap() {
        let s = Screen(cols: 4, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("abcde")
        XCTAssertEqual(s.plainString(), "abcd\ne")
        XCTAssertTrue(s.isWrapped(0))
    }

    func testRISClears() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("hello")
        p.feed("\u{1B}c")
        XCTAssertEqual(s.plainString(), "")
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 0)
    }

    func testLinuxFnDoesNotSwallow() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[[A")
        XCTAssertEqual(s.plainString(), "A")
    }

    func testIncompleteOSCDoesNotLeak() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]0;title")
        p.feed("X")
        XCTAssertEqual(s.plainString(), "")
        p.feed("\u{07}")
        p.feed("Y")
        XCTAssertEqual(s.plainString(), "Y")
    }

    func testDA1() {
        let p = Parser()
        p.feed("\u{1B}[c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1;2c")
    }

    func testDA2() {
        let p = Parser()
        p.feed("\u{1B}[>c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[>0;0;0c")
        p.writes.removeAll()
        p.feed("\u{1B}[>0c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[>0;0;0c")
        p.writes.removeAll()
        p.feed("\u{1B}[c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1;2c")
    }

    func testDECRQM2026() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2026$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2026;2$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?2026h")
        p.feed("\u{1B}[?2026$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2026;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?2026l")
        p.feed("\u{1B}[?2026$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2026;2$y")
        XCTAssertFalse(s.syncOutput)
        p.feed("\u{1B}[?2026h")
        XCTAssertTrue(s.syncOutput)
    }

    func testDec2026HoldTimeout() {
        XCTAssertTrue(Dec2026.skipPresent(sync: true, flush: false, holdStart: 0, now: 1))
        XCTAssertTrue(Dec2026.skipPresent(sync: true, flush: false, holdStart: 10, now: 10))
        XCTAssertTrue(Dec2026.skipPresent(
            sync: true, flush: false, holdStart: 10, now: 10 + Dec2026.timeoutNs - 1))
        XCTAssertFalse(Dec2026.skipPresent(
            sync: true, flush: false, holdStart: 10, now: 10 + Dec2026.timeoutNs))
        XCTAssertFalse(Dec2026.skipPresent(sync: false, flush: false, holdStart: 10, now: 10))
        XCTAssertFalse(Dec2026.skipPresent(sync: true, flush: true, holdStart: 0, now: 1))
    }

    func testDec2026LThenHStillFlushes() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2026h")
        XCTAssertTrue(s.syncOutput)
        XCTAssertFalse(s.syncFlush)
        p.feed("\u{1B}[?2026l\u{1B}[?2026h")
        XCTAssertTrue(s.syncOutput)
        XCTAssertTrue(s.syncFlush)
        XCTAssertFalse(Dec2026.skipPresent(
            sync: s.syncOutput, flush: s.syncFlush, holdStart: 0, now: 1))
    }

    func testDECRQMDefaultsAndPermanent() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?1007$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1007;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?25$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?25;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?3$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?3;4$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1005$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1005;4$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?9999$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?9999;0$y")
        p.writes.removeAll()
        p.feed("\u{1B}[4$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[4;2$y")
        p.writes.removeAll()
        p.feed("\u{1B}[4h")
        p.feed("\u{1B}[4$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[4;1$y")
    }

    func testDECRQMMouseAndAlt() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?1000;1006h")
        p.feed("\u{1B}[?1000$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1000;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1006$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1006;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1049h")
        p.feed("\u{1B}[?1049$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1049;1$y")
    }

    func testBracketedPasteAndFocusModes() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertFalse(s.focusEvent)
        p.feed("\u{1B}[?2004;1004h")
        XCTAssertTrue(s.bracketedPaste)
        XCTAssertTrue(s.focusEvent)
        p.feed("\u{1B}[?2004$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2004;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1004$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1004;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?2004l")
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertTrue(s.focusEvent)
        p.feed("\u{1B}c")
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertFalse(s.focusEvent)
    }

    func testOSCTitleAndST() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]0;hello\u{07}")
        XCTAssertEqual(p.titles, ["hello"])
        p.feed("\u{1B}]2;world\u{1B}\\")
        XCTAssertEqual(p.titles.last, "world")
        p.feed("\u{1B}]0;\u{202A}bad\u{07}")
        XCTAssertEqual(p.titles.last, "bad")
    }

    func testOSC4AndDefaults() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]4;1;#FF0000\u{07}")
        XCTAssertEqual(s.paletteColor(1), RGB(r: 255, g: 0, b: 0))
        p.writes.removeAll()
        p.feed("\u{1B}]4;1;?\u{07}")
        let q = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(q.contains("]4;1;rgb:FFFF/0000/0000"), q)
        p.feed("\u{1B}]10;#010203\u{07}")
        XCTAssertEqual(s.defaultFgRGB, RGB(r: 1, g: 2, b: 3))
        p.feed("\u{1B}]11;rgb:00/FF/00\u{07}")
        XCTAssertEqual(s.defaultBgRGB, RGB(r: 0, g: 255, b: 0))
        p.feed("\u{1B}]112\u{07}")
        p.feed("\u{1B}]10;?\u{07}")
        XCTAssertTrue((String(bytes: p.writes, encoding: .utf8) ?? "").contains("]10;"))
    }

    func testOSC52() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(p.osc52Writes.count, 1)
        XCTAssertEqual(p.osc52Writes[0].kind, UInt8(ascii: "c"))
        XCTAssertEqual(String(bytes: p.osc52Writes[0].b64, encoding: .ascii), "aGVsbG8=")
        p.feed("\u{1B}]52;c;?\u{07}")
        XCTAssertEqual(p.osc52Reads, [UInt8(ascii: "c")])
        p.feed("\u{1B}]52;x;?\u{07}")
        XCTAssertEqual(p.osc52Reads.last, UInt8(ascii: "c"))
    }

    func testOSC8And7And133() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]8;id=foo;https://example.com\u{07}A")
        XCTAssertNotEqual(s.row(0)[0].extra, 0)
        XCTAssertEqual(s.uri(at: 0, y: 0), "https://example.com")
        p.feed("\u{1B}]8;;\u{07}B")
        XCTAssertEqual(s.row(0)[1].extra, 0)
        p.feed("\u{1B}]7;file://host/tmp\u{07}")
        XCTAssertEqual(p.osc7.last, "file://host/tmp")
        p.feed("\u{1B}]133;A\u{07}")
        XCTAssertEqual(p.osc133.last?.0, UInt8(ascii: "A"))
    }

    func testCSI14And18t() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        var kinds: [Int32] = []
        p.onSizeReport = { kinds.append($0) }
        p.feed("\u{1B}[14t")
        p.feed("\u{1B}[18t")
        p.feed("\u{1B}[14;1t")
        XCTAssertEqual(kinds, [14, 18])
    }

    func testSizeReportUnderParseLock() {
        let session = TerminalSession(cols: 10, rows: 5, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0)
        var replies: [UInt8] = []
        session.parser.ptyWriter = { replies.append(contentsOf: $0) }
        session.lock.lock()
        session.parser.feed("\u{1B}[18t\u{1B}[14t")
        session.lock.unlock()
        let text = String(bytes: replies, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\u{1B}[8;5;10t"), text)
        XCTAssertTrue(text.contains("\u{1B}[4;80;80t"), text)
    }

    func testDECSCUSR() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[3 q")
        XCTAssertEqual(s.cursorStyle, 3)
        p.feed("\u{1B}[0 q")
        XCTAssertEqual(s.cursorStyle, 0)
        p.feed("\u{1B}[6 q")
        XCTAssertEqual(s.cursorStyle, 6)
    }

    func testUTF8Scalar() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("é")
        XCTAssertEqual(s.glyph(0, 0), 0xE9)
    }

    func testScanPrintableStopsAtESC() {
        let bytes: [UInt8] = [0x41, 0x42, 0x1B, 0x43]
        XCTAssertEqual(jt_scan_printable_ascii(bytes, bytes.count), 2)
        XCTAssertEqual(jt_scan_until_c0(bytes, bytes.count), 2)
        XCTAssertEqual(jt_scan_first_esc(bytes, bytes.count), 2)
    }

    func testSmacsQIsHline() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}(0q")
        XCTAssertEqual(s.glyph(0, 0), 0x2500)
        p.feed("\u{1B}(Bq")
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "q")))
    }

    func testSOandSI() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{0E}x")
        XCTAssertEqual(s.glyph(0, 0), 0x2502)
        p.feed("\u{0F}x")
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "x")))
    }

    func testSGRIndexedAndBold() {
        let s = Screen(cols: 20, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[31;1mA")
        XCTAssertEqual(s.penFG, PackedColor.indexed(1))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_BOLD), UInt16(ATTR_BOLD))
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "A")))
        p.feed("\u{1B}[91mB")
        XCTAssertEqual(s.penFG, PackedColor.indexed(9))
    }

    func testSGRTruecolorAndMixed() {
        let s = Screen(cols: 20, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[38;5;196;48;2;1;2;3mX")
        XCTAssertEqual(s.penFG, PackedColor.indexed(196))
        XCTAssertEqual(s.penBG, PackedColor.rgb(r: 1, g: 2, b: 3))
        p.feed("\u{1B}[38:2::10:20:30m")
        XCTAssertEqual(s.penFG, PackedColor.rgb(r: 10, g: 20, b: 30))
    }

    func testSGR21DoubleUnderline() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[31;21m")
        XCTAssertEqual(s.penFG, PackedColor.indexed(1))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_DOUBLE))
    }

    func testSGRSmulxStrikeOverlineBlink() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[4:3m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_CURLY))
        p.feed("\u{1B}[4:4m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_DOTTED))
        p.feed("\u{1B}[4:5m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_DASHED))
        p.feed("\u{1B}[9;53;5m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_STRIKETHROUGH), UInt16(ATTR_STRIKETHROUGH))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_OVERLINE), UInt16(ATTR_OVERLINE))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_BLINK), UInt16(ATTR_BLINK))
        p.feed("\u{1B}[24;29;55;25m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), 0)
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_STRIKETHROUGH), 0)
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_OVERLINE), 0)
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_BLINK), 0)
    }

    func testCUP() {
        let s = Screen(cols: 20, rows: 10, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[5;8H")
        XCTAssertEqual(s.cursorY, 4)
        XCTAssertEqual(s.cursorX, 7)
    }
}
