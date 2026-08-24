import XCTest
@testable import Jetty

final class ScrollSearchTests: XCTestCase {
    func testSubstringCaseInsensitive() {
        let s = Screen(cols: 8, rows: 2, scrollbackCapRows: 8)
        s.printRun("HelloXxx")
        s.printRun("WORLDYYY")
        let hits = ScrollSearch.hits(query: "hello", screen: s, liveRows: 2)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].spans.count, 1)
        XCTAssertEqual(hits[0].spans[0].x0, 0)
        XCTAssertEqual(hits[0].spans[0].x1, 4)
    }

    func testWrapJoinMatch() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 8)
        let p = Parser()
        p.screen = s
        p.feed("ABCDEFGHIJKL")
        XCTAssertTrue(s.isHistoryWrapped(0))
        let hits = ScrollSearch.hits(query: "cdef", screen: s, liveRows: 2)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].spans.count, 2)
        let byRow = Dictionary(uniqueKeysWithValues: hits[0].spans.map { ($0.docRow, $0) })
        XCTAssertEqual(byRow[0]?.x0, 2)
        XCTAssertEqual(byRow[0]?.x1, 3)
        XCTAssertEqual(byRow[1]?.x0, 0)
        XCTAssertEqual(byRow[1]?.x1, 1)
    }

    func testEmptyQueryNoHits() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 4)
        s.printRun("ABCD")
        XCTAssertEqual(ScrollSearch.hits(query: "", screen: s, liveRows: 2).count, 0)
    }
}
