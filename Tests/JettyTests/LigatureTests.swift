import CoreText
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
        var twoColor = Array("=>      ".utf8).map { ascii($0) }
        twoColor[0].fg = PackedColor.indexed(2)
        twoColor[1].fg = PackedColor.indexed(3)
        let nFg = twoColor.withUnsafeBufferPointer { buf in
            ProgrammingLigatures.spanLength(row: buf.baseAddress!, x: 0, cols: cols)
        }
        XCTAssertEqual(nFg, 0)
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
        let arrow = shape(shaper, "=>", font: featured, feature: "")
        XCTAssertTrue(arrow.ligated.contains(true), "\(arrow.cells)")
        let hello = shape(shaper, "hello", font: featured, feature: "")
        XCTAssertFalse(hello.ligated.contains(true), "\(hello.cells)")
    }

    func testCaltOffDoesNotLigateArrow() {
        EmbeddedFonts.registerIfNeeded()
        let font = EmbeddedFonts.font(size: 20, bold: false, italic: false)
        let shaper = ShaperCache()
        let featured = shaper.featuredFont(font, feature: "-calt")
        let shaped = shape(shaper, "=>", font: featured, feature: "-calt")
        XCTAssertFalse(shaped.ligated.contains(true), "\(shaped.cells)")
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
        XCTAssertEqual(shaper.missCount, 1)
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
        XCTAssertEqual(shaper.missCount, 0)
    }

    func testCollectOnFiFlStDoNotLigate() {
        EmbeddedFonts.registerIfNeeded()
        for s in ["fi", "fl", "st"] {
            let cells = Array(s.utf8).map { ascii($0) }
            var hide = [UInt8](repeating: 0, count: cells.count)
            let shaper = ShaperCache()
            let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
            XCTAssertEqual(spans.count, 0, s)
            XCTAssertEqual(hide, [UInt8](repeating: 0, count: cells.count), s)
            XCTAssertEqual(shaper.missCount, 0, s)
        }
        let file = Array("file".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: file.count)
        let shaper = ShaperCache()
        let spans = collect(file, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0, 0, 0])
    }

    func testCollectOnHelloIsEmpty() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 5
        let cells = Array("hello".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cols)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0, 0, 0, 0])
        XCTAssertEqual(shaper.missCount, 1)
        hide = [UInt8](repeating: 0, count: cols)
        _ = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(shaper.missCount, 1)
    }

    func testCollectOnTwoColorArrowDoesNotLigate() {
        EmbeddedFonts.registerIfNeeded()
        var cells = Array("=>".utf8).map { ascii($0) }
        cells[0].fg = PackedColor.indexed(2)
        cells[1].fg = PackedColor.indexed(3)
        var hide = [UInt8](repeating: 0, count: 2)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0])
        XCTAssertEqual(shaper.missCount, 0)
    }

    func testCollectProgrammingTwoColorArrowDoesNotLigate() {
        EmbeddedFonts.registerIfNeeded()
        var cells = Array("=>".utf8).map { ascii($0) }
        cells[0].fg = PackedColor.indexed(2)
        cells[1].fg = PackedColor.indexed(3)
        var hide = [UInt8](repeating: 0, count: 2)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .programming, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0])
        XCTAssertEqual(shaper.missCount, 0)
    }

    func testCollectProgrammingUnderlineArrowDoesNotLigate() {
        EmbeddedFonts.registerIfNeeded()
        var cells = Array("=>".utf8).map { ascii($0) }
        cells[1].attrs = UInt16(UL_SINGLE)
        var hide = [UInt8](repeating: 0, count: 2)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .programming, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [0, 0])
        XCTAssertEqual(shaper.missCount, 0)
    }

    func testCollectOnTwoArrowsAreOneRun() {
        EmbeddedFonts.registerIfNeeded()
        let cells = Array("=>a=>".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cells.count)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.map(\.x), [0, 3])
        XCTAssertEqual(spans.map(\.text), ["=>", "=>"])
        XCTAssertEqual(hide, [1, 1, 0, 1, 1])
        XCTAssertEqual(shaper.missCount, 1)
    }

    func testCollectOnHtmlComment() {
        EmbeddedFonts.registerIfNeeded()
        let cells = Array("<!--".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cells.count)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "<!--")
        XCTAssertEqual(hide, [1, 1, 1, 1])
    }

    func testCollectOnTripleEquals() {
        EmbeddedFonts.registerIfNeeded()
        let cells = Array("===".utf8).map { ascii($0) }
        var hide = [UInt8](repeating: 0, count: cells.count)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "===")
        XCTAssertEqual(hide, [1, 1, 1])
    }

    func testCollectOnPerCellFgDoesNotShape() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 8
        var cells = Array("abcdefgh".utf8).map { ascii($0) }
        for i in cells.indices {
            cells[i].fg = PackedColor.indexed(UInt8(i + 1))
        }
        var hide = [UInt8](repeating: 0, count: cols)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(hide, [UInt8](repeating: 0, count: cols))
        XCTAssertEqual(shaper.missCount, 0)
    }

    func testCollectOnTrimsTrailingEmpty() {
        EmbeddedFonts.registerIfNeeded()
        let cols = 6
        var cells = (0..<cols).map { _ in Cell.empty }
        cells[0] = ascii("=")
        cells[1] = ascii(">")
        var hide = [UInt8](repeating: 0, count: cols)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "=>")
        XCTAssertEqual(hide, [1, 1, 0, 0, 0, 0])
        XCTAssertEqual(shaper.missCount, 1)
    }

    func testCollectOnUnderlineBreaksRun() {
        EmbeddedFonts.registerIfNeeded()
        var cells = Array("ab".utf8).map { ascii($0) }
        cells[1].attrs = UInt16(UL_SINGLE)
        var hide = [UInt8](repeating: 0, count: 2)
        let shaper = ShaperCache()
        let spans = collect(cells, mode: .on, shaper: shaper, hide: &hide)
        XCTAssertEqual(spans.count, 0)
        XCTAssertEqual(shaper.missCount, 0)
    }

    private func shape(
        _ shaper: ShaperCache,
        _ s: String,
        font: CTFont,
        feature: String
    ) -> ShapedRun {
        let row = Array(s.utf8).map { ascii($0) }
        return row.withUnsafeBufferPointer { buf in
            let hash = ShaperCache.hashCells(row: buf.baseAddress!, start: 0, count: row.count)
            return shaper.shape(
                row: buf.baseAddress!, start: 0, count: row.count, contentHash: hash,
                font: font, fontPx: 20, bold: false, italic: false, feature: feature
            )
        }
    }

    private func collect(
        _ cells: [Cell],
        mode: AppConfig.Ligatures,
        shaper: ShaperCache,
        hide: inout [UInt8]
    ) -> [LigaSpan] {
        cells.withUnsafeBufferPointer { buf in
            hide.withUnsafeMutableBufferPointer { h in
                LigatureExpand.collect(
                    cells: buf.baseAddress!,
                    cols: cells.count,
                    rows: 1,
                    mode: mode,
                    shaper: shaper,
                    font: { b, i in EmbeddedFonts.font(size: 20, bold: b, italic: i) },
                    fontPx: 20,
                    feature: "",
                    hide: h.baseAddress!
                )
            }
        }
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
