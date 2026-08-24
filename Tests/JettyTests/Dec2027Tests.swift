import CVt
import XCTest
@testable import Jetty

final class Dec2027Tests: XCTestCase {
    func testDECRPMOffOnOff() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2027;2$y")
        XCTAssertFalse(s.mode2027)
        p.writes.removeAll()
        p.feed("\u{1B}[?2027h")
        p.feed("\u{1B}[?2027$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2027;1$y")
        XCTAssertTrue(s.mode2027)
        p.writes.removeAll()
        p.feed("\u{1B}[?2027l")
        p.feed("\u{1B}[?2027$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2027;2$y")
        XCTAssertFalse(s.mode2027)
    }

    func testRISClearsMode() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        XCTAssertTrue(s.mode2027)
        p.feed("\u{1B}c")
        XCTAssertFalse(s.mode2027)
    }

    func testInvalidVS16DoesNotIntern() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        p.feed("x\u{FE0F}a")
        let c0 = s.row(0)[0]
        XCTAssertEqual(c0.contentKind, CONTENT_SCALAR)
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "x")))
        XCTAssertEqual(c0.wide, WIDE_NARROW)
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "a")))
        XCTAssertEqual(s.cursorX, 2)
    }

    func testHeartVS16StaysWideCluster() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        p.feed("\u{2764}\u{FE0F}")
        let c0 = s.row(0)[0]
        XCTAssertEqual(c0.contentKind, CONTENT_GRAPHEME)
        XCTAssertEqual(c0.wide, WIDE_FULL)
        XCTAssertEqual(s.row(0)[1].wide, WIDE_TAIL)
        var n: UInt16 = 0
        let cps = jt_grapheme_get(s.implPtr, c0.contentPayload, &n)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(cps?[0], 0x2764)
        XCTAssertEqual(cps?[1], 0xFE0F)
        XCTAssertEqual(s.cursorX, 2)
    }

    func testDigitVS16BecomesWide() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        p.feed("1\u{FE0F}")
        let c0 = s.row(0)[0]
        XCTAssertEqual(c0.contentKind, CONTENT_GRAPHEME)
        XCTAssertEqual(c0.wide, WIDE_FULL)
        XCTAssertEqual(s.row(0)[1].wide, WIDE_TAIL)
        var n: UInt16 = 0
        let cps = jt_grapheme_get(s.implPtr, c0.contentPayload, &n)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(cps?[0], UInt32(UInt8(ascii: "1")))
        XCTAssertEqual(cps?[1], 0xFE0F)
        p.feed("a")
        XCTAssertEqual(s.glyph(2, 0), UInt32(UInt8(ascii: "a")))
    }

    func testZWJFamilyOneCluster() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        p.feed("\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}")
        let c0 = s.row(0)[0]
        XCTAssertEqual(c0.contentKind, CONTENT_GRAPHEME)
        XCTAssertEqual(c0.wide, WIDE_FULL)
        XCTAssertEqual(s.row(0)[1].wide, WIDE_TAIL)
        var n: UInt16 = 0
        let cps = jt_grapheme_get(s.implPtr, c0.contentPayload, &n)
        XCTAssertEqual(n, 7)
        XCTAssertEqual(cps?[0], 0x1F469)
        XCTAssertEqual(cps?[6], 0x1F466)
        XCTAssertEqual(s.cursorX, 2)
    }

    func testOffKeepsBaseWidthAndInternsVS16() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("x\u{FE0F}")
        let c0 = s.row(0)[0]
        XCTAssertEqual(c0.contentKind, CONTENT_GRAPHEME)
        XCTAssertEqual(c0.wide, WIDE_NARROW)
        XCTAssertEqual(s.cursorX, 1)
    }

    func testCombiningStillInternsWhenOn() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        p.feed("e\u{0301}")
        let c = s.row(0)[0]
        XCTAssertEqual(c.contentKind, CONTENT_GRAPHEME)
        XCTAssertEqual(c.wide, WIDE_NARROW)
        var n: UInt16 = 0
        let cps = jt_grapheme_get(s.implPtr, c.contentPayload, &n)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(cps?[0], UInt32(UInt8(ascii: "e")))
        XCTAssertEqual(cps?[1], 0x0301)
    }

    func testASCIIRunUntouched() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2027h")
        p.feed("y\n")
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "y")))
        XCTAssertEqual(s.row(0)[0].contentKind, CONTENT_SCALAR)
        XCTAssertEqual(s.cursorY, 1)
    }

    func testGraphemeBreakEmojiModifier() {
        var state: UInt8 = 0
        XCTAssertEqual(jt_grapheme_break(0x261D, 0x1F3FF, &state), 0)
        state = 0
        XCTAssertEqual(jt_grapheme_break(0x22, 0x1F3FF, &state), 1)
    }

    func testWidthEffectMatchesGhostty() {
        XCTAssertEqual(jt_grapheme_width_effect(0x2764, 0xFE0F), Int32(JT_GB_WIDE))
        XCTAssertEqual(jt_grapheme_width_effect(0x23, 0xFE0E), Int32(JT_GB_NARROW))
        XCTAssertEqual(jt_grapheme_width_effect(UInt32(UInt8(ascii: "x")), 0xFE0F), Int32(JT_GB_IGNORE))
        XCTAssertTrue(jt_gb_emoji_vs_base(0x2764) != 0)
        XCTAssertTrue(jt_gb_emoji_vs_base(UInt32(UInt8(ascii: "1"))) != 0)
        XCTAssertTrue(jt_gb_emoji_vs_base(UInt32(UInt8(ascii: "x"))) == 0)
    }
}
