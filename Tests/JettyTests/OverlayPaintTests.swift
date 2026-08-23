import CVt
import XCTest
@testable import Jetty

final class OverlayPaintTests: XCTestCase {
    func testSingleDoubleCurlyCounts() {
        let w: Float = 12, h: Float = 24
        XCTAssertEqual(OverlayPaint.count(attrs: UInt16(UL_SINGLE), wide: WIDE_NARROW, cellW: w, cellH: h), 1)
        XCTAssertEqual(OverlayPaint.count(attrs: UInt16(UL_DOUBLE), wide: WIDE_NARROW, cellW: w, cellH: h), 2)
        XCTAssertEqual(OverlayPaint.count(attrs: UInt16(UL_CURLY), wide: WIDE_NARROW, cellW: w, cellH: h), 4)
        XCTAssertEqual(OverlayPaint.count(attrs: 0, wide: WIDE_NARROW, cellW: w, cellH: h), 0)
        XCTAssertEqual(OverlayPaint.count(attrs: UInt16(UL_SINGLE), wide: WIDE_TAIL, cellW: w, cellH: h), 0)
        XCTAssertEqual(OverlayPaint.count(attrs: UInt16(UL_SINGLE), wide: WIDE_HEAD, cellW: w, cellH: h), 0)
    }

    func testStrikeOverlineAddOneEach() {
        let w: Float = 12, h: Float = 24
        let both = UInt16(ATTR_STRIKETHROUGH | ATTR_OVERLINE)
        XCTAssertEqual(OverlayPaint.count(attrs: both, wide: WIDE_NARROW, cellW: w, cellH: h), 2)
        XCTAssertEqual(
            OverlayPaint.count(attrs: UInt16(UL_DOUBLE) | both, wide: WIDE_NARROW, cellW: w, cellH: h),
            4
        )
    }

    func testDottedDashedCeilThenCapAtCellW() {
        let cellW: Float = 10, cellH: Float = 24
        let t = OverlayPaint.thickness(cellH)
        let dot = max(1 as Float, t * 2)
        XCTAssertEqual(
            OverlayPaint.count(attrs: UInt16(UL_DOTTED), wide: WIDE_NARROW, cellW: cellW, cellH: cellH),
            OverlayPaint.dashCount(cellW: cellW, on: dot, off: dot)
        )
        XCTAssertEqual(
            OverlayPaint.count(attrs: UInt16(UL_DASHED), wide: WIDE_NARROW, cellW: cellW, cellH: cellH),
            OverlayPaint.dashCount(cellW: cellW, on: 3 * dot, off: 2 * dot)
        )
        let n = OverlayPaint.dashCount(cellW: cellW, on: dot, off: dot)
        XCTAssertEqual(n, min(Int(ceil(Double(cellW / (dot + dot)))), Int(floor(Double(cellW)))))
        XCTAssertLessThanOrEqual(n, Int(floor(Double(cellW))))
        XCTAssertGreaterThan(n, 0)
    }
}
