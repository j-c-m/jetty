import CVt
import XCTest
@testable import Jetty

final class LigatureTests: XCTestCase {
    func testTableIsLongestFirst() {
        let t = ProgrammingLigatures.table
        XCTAssertEqual(Set(t), Set(ProgrammingLigatures.raw))
        XCTAssertGreaterThanOrEqual(t.first?.count ?? 0, t.last?.count ?? 0)
        XCTAssertTrue(t.contains("=>"))
        XCTAssertTrue(t.contains("!=="))
        XCTAssertTrue(t.contains("///"))
        XCTAssertTrue(t.contains("<=>"))
        XCTAssertTrue(t.contains("||="))
        XCTAssertTrue(t.contains("<!--"))
        XCTAssertTrue(t.contains("####"))
        XCTAssertTrue(t.contains("__"))
        XCTAssertEqual(t.count, Set(t).count)
        let iEq = t.firstIndex(of: "==")!
        let iNeqeq = t.firstIndex(of: "!==")!
        XCTAssertLessThan(iNeqeq, iEq)
        XCTAssertLessThan(t.firstIndex(of: "///")!, t.firstIndex(of: "//")!)
        XCTAssertLessThan(t.firstIndex(of: "<=>")!, t.firstIndex(of: "<=")!)
        XCTAssertLessThan(t.firstIndex(of: "<==>")!, t.firstIndex(of: "<=>")!)
        XCTAssertLessThan(t.firstIndex(of: "||=")!, t.firstIndex(of: "||")!)
        XCTAssertLessThan(t.firstIndex(of: "####")!, t.firstIndex(of: "###")!)
        XCTAssertLessThan(t.firstIndex(of: "...")!, t.firstIndex(of: "..")!)
        XCTAssertLessThan(t.firstIndex(of: "<!--")!, t.firstIndex(of: "</")!)
    }

    func testSpanMatchConsumesLongest() {
        let cols = 8
        var row = (0..<cols).map { _ in ascii(" ") }
        row[0] = ascii("=")
        row[1] = ascii("=")
        row[2] = ascii("=")
        let n = row.withUnsafeBufferPointer { buf in
            ProgrammingLigatures.spanLength(row: buf.baseAddress!, x: 0, cols: cols)
        }
        XCTAssertEqual(n, 3)
        let n2 = row.withUnsafeBufferPointer { buf in
            ProgrammingLigatures.spanLength(row: buf.baseAddress!, x: 1, cols: cols)
        }
        XCTAssertEqual(n2, 0)
        func span(_ s: String) -> Int {
            let row = Array(s.utf8).map { ascii($0) }
            XCTAssertEqual(row.count, cols)
            return row.withUnsafeBufferPointer { buf in
                ProgrammingLigatures.spanLength(row: buf.baseAddress!, x: 0, cols: cols)
            }
        }
        XCTAssertEqual(span("///     "), 3)
        XCTAssertEqual(span("<=>     "), 3)
        XCTAssertEqual(span("||=     "), 3)
        XCTAssertEqual(span("<!--    "), 4)
        XCTAssertEqual(span("####    "), 4)
        XCTAssertEqual(span("<==>    "), 4)
        XCTAssertEqual(span("...     "), 3)
        XCTAssertEqual(span("====    "), 0)
        XCTAssertEqual(span("======  "), 0)
        XCTAssertEqual(span("----    "), 0)
        XCTAssertEqual(span("#####   "), 0)
        XCTAssertEqual(span("....    "), 0)
        XCTAssertEqual(span("+++ x   "), 3)
        XCTAssertEqual(span("++++    "), 0)
        XCTAssertEqual(span("=== === "), 3)
        XCTAssertEqual(span("=>      "), 2)
    }

    func testHelloIsNotASpan() {
        let cols = 5
        let row = Array("hello".utf8).map { ascii($0) }
        let n = row.withUnsafeBufferPointer { buf in
            ProgrammingLigatures.spanLength(row: buf.baseAddress!, x: 0, cols: cols)
        }
        XCTAssertEqual(n, 0)
    }

    func testArrowShapesAsLigature() {
        EmbeddedFonts.registerIfNeeded()
        let font = EmbeddedFonts.font(size: 20, bold: false, italic: false)
        let shaper = ShaperCache()
        let featured = shaper.featuredFont(font, feature: "")
        let shaped = shaper.shape(text: "=>", font: featured, fontPx: 20)
        XCTAssertTrue(ShaperCache.isLigature(shaped, text: "=>", font: featured), "\(shaped)")
        let hello = shaper.shape(text: "hello", font: featured, fontPx: 20)
        XCTAssertFalse(ShaperCache.isLigature(hello, text: "hello", font: featured), "\(hello)")
    }

    func testCaltOffDoesNotLigateArrow() {
        EmbeddedFonts.registerIfNeeded()
        let font = EmbeddedFonts.font(size: 20, bold: false, italic: false)
        let shaper = ShaperCache()
        let featured = shaper.featuredFont(font, feature: "-calt")
        let shaped = shaper.shape(text: "=>", font: featured, fontPx: 20)
        XCTAssertFalse(ShaperCache.isLigature(shaped, text: "=>", font: featured), "\(shaped)")
    }

    func testCollectProgrammingHidesArrowOnly() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 6
        let cells = Array("ab=>cd".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cols)
        let shaper = ShaperCache()
        let spans = cells.withUnsafeBufferPointer { buf in
            hide.withUnsafeMutableBufferPointer { h in
                LigatureExpand.collect(
                    cells: buf.baseAddress!,
                    cols: cols,
                    rows: 1,
                    mode: .programming,
                    shaper: shaper,
                    font: { b, i in EmbeddedFonts.font(size: 20, bold: b, italic: i) },
                    fontPx: 20,
                    feature: "",
                    hide: h.baseAddress!
                )
            }
        }
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "=>")
        XCTAssertEqual(spans[0].x, 2)
        XCTAssertEqual(hide, [0, 0, 1, 1, 0, 0])
    }

    func testCollectOnHidesArrowOnly() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 6
        let cells = Array("ab=>cd".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cols)
        let shaper = ShaperCache()
        let spans = cells.withUnsafeBufferPointer { buf in
            hide.withUnsafeMutableBufferPointer { h in
                LigatureExpand.collect(
                    cells: buf.baseAddress!,
                    cols: cols,
                    rows: 1,
                    mode: .on,
                    shaper: shaper,
                    font: { b, i in EmbeddedFonts.font(size: 20, bold: b, italic: i) },
                    fontPx: 20,
                    feature: "",
                    hide: h.baseAddress!
                )
            }
        }
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "=>")
        XCTAssertEqual(spans[0].x, 2)
        XCTAssertEqual(hide, [0, 0, 1, 1, 0, 0])
    }

    func testCollectOffIsEmpty() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 2
        let cells = Array("=>".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 1, count: cols)
        let shaper = ShaperCache()
        let spans = cells.withUnsafeBufferPointer { buf in
            hide.withUnsafeMutableBufferPointer { h in
                LigatureExpand.collect(
                    cells: buf.baseAddress!,
                    cols: cols,
                    rows: 1,
                    mode: .off,
                    shaper: shaper,
                    font: { b, i in EmbeddedFonts.font(size: 20, bold: b, italic: i) },
                    fontPx: 20,
                    feature: "",
                    hide: h.baseAddress!
                )
            }
        }
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0])
    }

    func testCollectProgrammingHelloIsEmpty() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 5
        let cells = Array("hello".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cols)
        let shaper = ShaperCache()
        let spans = cells.withUnsafeBufferPointer { buf in
            hide.withUnsafeMutableBufferPointer { h in
                LigatureExpand.collect(
                    cells: buf.baseAddress!,
                    cols: cols,
                    rows: 1,
                    mode: .programming,
                    shaper: shaper,
                    font: { b, i in EmbeddedFonts.font(size: 20, bold: b, italic: i) },
                    fontPx: 20,
                    feature: "",
                    hide: h.baseAddress!
                )
            }
        }
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0, 0, 0, 0])
    }

    private func ascii(_ ch: UInt8) -> Cell {
        var c = Cell.empty
        c.content = content_scalar(UInt32(ch), WIDE_NARROW)
        return c
    }

    private func ascii(_ ch: Character) -> Cell {
        ascii(ch.utf8.first!)
    }
}
