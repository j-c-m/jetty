import XCTest
@testable import Jetty

final class CellSelectionTests: XCTestCase {
    func testStreamFillsMidRows() {
        let s = (x0: 2, y0: 1, x1: 5, y1: 4)
        XCTAssertEqual(CellSelection.columns(s, row: 0, cols: 10)?.lo, nil)
        XCTAssertEqual(CellSelection.columns(s, row: 1, cols: 10)?.lo, 2)
        XCTAssertEqual(CellSelection.columns(s, row: 1, cols: 10)?.hi, 9)
        XCTAssertEqual(CellSelection.columns(s, row: 2, cols: 10)?.lo, 0)
        XCTAssertEqual(CellSelection.columns(s, row: 2, cols: 10)?.hi, 9)
        XCTAssertEqual(CellSelection.columns(s, row: 4, cols: 10)?.lo, 0)
        XCTAssertEqual(CellSelection.columns(s, row: 4, cols: 10)?.hi, 5)
    }

    func testRectClampsEveryRow() {
        let s = (x0: 5, y0: 4, x1: 2, y1: 1)
        let mid = CellSelection.columns(s, row: 2, cols: 10, rect: true)
        XCTAssertEqual(mid?.lo, 2)
        XCTAssertEqual(mid?.hi, 5)
        XCTAssertEqual(CellSelection.columns(s, row: 1, cols: 10, rect: true)?.lo, 2)
        XCTAssertEqual(CellSelection.columns(s, row: 4, cols: 10, rect: true)?.hi, 5)
        XCTAssertNil(CellSelection.columns(s, row: 0, cols: 10, rect: true))
        XCTAssertNil(CellSelection.columns(s, row: 5, cols: 10, rect: true))
    }
}
