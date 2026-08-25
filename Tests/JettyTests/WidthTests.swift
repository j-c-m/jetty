import CVt
import XCTest
@testable import Jetty

final class WidthTests: XCTestCase {
    func testCodepointWidthGoldens() {
        XCTAssertEqual(jt_codepoint_width(UInt32(UInt8(ascii: "a"))), 1)
        XCTAssertEqual(jt_codepoint_width(0x20), 1)
        XCTAssertEqual(jt_codepoint_width(0x10FFFF), 1)
        XCTAssertEqual(jt_codepoint_width(0x10EEEE), 1)
        XCTAssertEqual(jt_codepoint_width(0x00), 0)
        XCTAssertEqual(jt_codepoint_width(0x1B), 0)
        XCTAssertEqual(jt_codepoint_width(0x0301), 0)
        XCTAssertEqual(jt_codepoint_width(0x200D), 0)
        XCTAssertEqual(jt_codepoint_width(0xFE0F), 0)
        XCTAssertEqual(jt_codepoint_width(0x4E00), 2)
        XCTAssertEqual(jt_codepoint_width(0x1F600), 2)
        XCTAssertEqual(jt_codepoint_width(0x1F1E6), 2)
        XCTAssertEqual(jt_codepoint_width(0x2E3B), 2)
    }

    func testCJKOccupiesTwoCells() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("中")
        XCTAssertEqual(s.glyph(0, 0), 0x4E2D)
        XCTAssertEqual(s.row(0)[0].wide, WIDE_FULL)
        XCTAssertEqual(s.row(0)[1].wide, WIDE_TAIL)
        XCTAssertEqual(s.cursorX, 2)
    }

    func testUTF8TwoByteAndSplitCJK() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("é中A")
        XCTAssertEqual(s.glyph(0, 0), 0xE9)
        XCTAssertEqual(s.glyph(1, 0), 0x4E2D)
        XCTAssertEqual(s.row(0)[2].wide, WIDE_TAIL)
        XCTAssertEqual(s.glyph(3, 0), UInt32(UInt8(ascii: "A")))
    }

    func testUTF8NeonThreeByteRun() {
        let s = Screen(cols: 40, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("é一二三四五六")
        XCTAssertEqual(s.glyph(0, 0), 0xE9)
        let cjk: [UInt32] = [0x4E00, 0x4E8C, 0x4E09, 0x56DB, 0x4E94, 0x516D]
        var x = 1
        for cp in cjk {
            XCTAssertEqual(s.glyph(x, 0), cp)
            XCTAssertEqual(s.row(0)[x].wide, WIDE_FULL)
            XCTAssertEqual(s.row(0)[x + 1].wide, WIDE_TAIL)
            x += 2
        }
        XCTAssertEqual(s.cursorX, 13)

        var overlong = [UInt8]()
        for _ in 0..<6 { overlong += [0xE0, 0x81, 0x81] }
        let s2 = Screen(cols: 16, rows: 2, scrollbackCapRows: 0)
        let p2 = Parser()
        p2.screen = s2
        p2.feed(overlong)
        XCTAssertEqual(s2.glyph(0, 0), 0xFFFD)
        XCTAssertNotEqual(s2.glyph(0, 0), 0x41)

        let s3 = Screen(cols: 40, rows: 2, scrollbackCapRows: 0)
        let p3 = Parser()
        p3.screen = s3
        let cjkRun = Array("一二三四五六".utf8)
        p3.feed([cjkRun[0]])
        p3.feed(Array(cjkRun.dropFirst()))
        XCTAssertEqual(s3.glyph(0, 0), 0x4E00)
        XCTAssertEqual(s3.glyph(10, 0), 0x516D)
        XCTAssertEqual(s3.cursorX, 12)
    }

    func testUnicodeParseCost() {
        var chunk = [UInt8]()
        for i in 0x4E00..<0x4E00 + 2048 {
            let cp = UInt32(i)
            chunk.append(UInt8(0xE0 | (cp >> 12)))
            chunk.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            chunk.append(UInt8(0x80 | (cp & 0x3F)))
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(1_048_576)
        while bytes.count < 1_048_576 { bytes.append(contentsOf: chunk) }
        func minMs(_ trials: Int, _ body: (Parser) -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<trials {
                let s = Screen(cols: 105, rows: 35, scrollbackCapRows: 0)
                s.switchScreenMode(1049, enabled: true)
                let p = Parser()
                p.screen = s
                let t0 = ProcessInfo.processInfo.systemUptime
                body(p)
                best = min(best, (ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            return best
        }
        let one = minMs(3) { $0.feed(bytes) }
        let sliced = minMs(3) { p in
            bytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var off = 0
                while off < buf.count {
                    let n = min(4096, buf.count - off)
                    p.feed(base.advanced(by: off), count: n)
                    off += n
                }
            }
        }
        fputs(String(format: "unicode parse 1MiB CJK ms=%.2f slice4096=%.2f\n", one, sliced), stderr)
        fflush(stderr)
        XCTAssertLessThan(one, 50)
        XCTAssertLessThan(sliced, 50)
    }

    func testWideWrapsWithHead() {
        let s = Screen(cols: 4, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("ABC中")
        XCTAssertEqual(s.row(0)[3].wide, WIDE_HEAD)
        XCTAssertTrue(s.isWrapped(0))
        XCTAssertEqual(s.row(1)[0].wide, WIDE_FULL)
        XCTAssertEqual(s.row(1)[1].wide, WIDE_TAIL)
        XCTAssertEqual(s.glyph(0, 1), 0x4E2D)
    }

    func testCombiningInternsGrapheme() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("e\u{0301}")
        let c = s.row(0)[0]
        XCTAssertEqual(c.contentKind, CONTENT_GRAPHEME)
        var n: UInt16 = 0
        let cps = jt_grapheme_get(s.implPtr, c.contentPayload, &n)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(cps?[0], UInt32(UInt8(ascii: "e")))
        XCTAssertEqual(cps?[1], 0x0301)
        XCTAssertEqual(s.cursorX, 1)
    }

    func testSGR58InternsRare() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[58:2::1:2:3mA")
        XCTAssertNotEqual(s.implPtr.pointee.pen.extra, 0)
        XCTAssertEqual(s.row(0)[0].extra, s.implPtr.pointee.pen.extra)
        var rare = jt_rare()
        XCTAssertEqual(jt_rare_get(s.implPtr, s.row(0)[0].extra, &rare), 1)
        XCTAssertEqual(rare.ul_color, PackedColor.rgb(r: 1, g: 2, b: 3))
    }

    func testRareOverflowDrops() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 0)
        var last: UInt16 = 0
        for i in 0..<1025 {
            let id = jt_rare_intern(s.implPtr, nil, "u\(i)", PackedColor.indexed(UInt8(i % 200)))
            if i < 1024 {
                XCTAssertNotEqual(id, 0, "i=\(i)")
                jt_rare_retain(s.implPtr, id)
                last = id
            } else {
                XCTAssertEqual(id, 0)
            }
        }
        XCTAssertNotEqual(last, 0)
    }

    func testBGRAShelfGrows() {
        let shelf = BGRAShelf(edge: 8, maxEdge: 32)
        let px = [UInt8](repeating: 9, count: 8 * 8 * 4)
        let ra = shelf.allocate(width: 8, height: 8)!
        shelf.blit(px, width: 8, height: 8, x: ra.x, y: ra.y)
        XCTAssertNil(shelf.allocate(width: 8, height: 4))
        XCTAssertNotNil(shelf.grow())
        XCTAssertEqual(shelf.width, 16)
        let rc = shelf.allocate(width: 8, height: 4)!
        XCTAssertEqual(rc.y, 8)
    }
}
