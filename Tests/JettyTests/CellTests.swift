import CVt
import XCTest
@testable import Jetty

final class CellTests: XCTestCase {
    func testSizeAndLayout() {
        XCTAssertEqual(MemoryLayout<Cell>.size, 16)
        XCTAssertEqual(MemoryLayout<Cell>.stride, 16)
        XCTAssertEqual(MemoryLayout<Cell>.alignment, 4)
        XCTAssertEqual(MemoryLayout.offset(of: \Cell.extra), 14)
        XCTAssertEqual(jt_cell_extra_offset(), 14)
    }

    func testZeroIsDefaultEmpty() {
        let c = Cell.empty
        XCTAssertEqual(c.content, 0)
        XCTAssertEqual(c.fg, COLOR_DEFAULT)
        XCTAssertEqual(c.bg, COLOR_DEFAULT)
        XCTAssertEqual(c.attrs, 0)
        XCTAssertEqual(c.extra, 0)
        XCTAssertEqual(c.colorTypeFG, 0)
        XCTAssertEqual(c.colorTypeBG, 0)
        XCTAssertNil(c.indexedFG)
        XCTAssertNil(c.indexedBG)
        XCTAssertEqual(c.wide, WIDE_NARROW)
        XCTAssertEqual(c.contentKind, CONTENT_SCALAR)
    }

    func testIndexedColorWord() {
        XCTAssertEqual(PackedColor.indexed(1), COLOR_INDEXED | 1)
        XCTAssertEqual(PackedColor.indexed(9), 0x01000009)
        XCTAssertEqual(PackedColor.indexed(196), 0x010000C4)
        XCTAssertEqual(PackedColor.type(of: PackedColor.indexed(196)), 1)
        XCTAssertEqual(PackedColor.payload(of: PackedColor.indexed(196)), 196)
    }

    func testMixedIndexedFgRgbBg() {
        var c = Cell.empty
        c.fg = PackedColor.indexed(196)
        c.bg = PackedColor.rgb(r: 1, g: 2, b: 3)
        XCTAssertEqual(c.indexedFG, 196)
        XCTAssertNil(c.indexedBG)
        XCTAssertEqual(c.colorTypeFG, 1)
        XCTAssertEqual(c.colorTypeBG, 2)
        XCTAssertEqual(PackedColor.payload(of: c.bg), 0x00010203)
        XCTAssertEqual(c.fg, color_indexed(196))
        XCTAssertEqual(c.bg, color_rgb(1, 2, 3))
    }

    func testWideBits() {
        var c = Cell.empty
        c.content = content_scalar(0x41, WIDE_FULL)
        XCTAssertEqual(c.wide, WIDE_FULL)
        XCTAssertEqual(c.contentPayload, 0x41)
        c.content = content_scalar(0, WIDE_TAIL)
        XCTAssertEqual(c.wide, WIDE_TAIL)
        c.content = content_scalar(0, WIDE_HEAD)
        XCTAssertEqual(c.wide, WIDE_HEAD)
        c.content = content_scalar(0x20, WIDE_NARROW)
        XCTAssertEqual(c.wide, WIDE_NARROW)
    }
}
