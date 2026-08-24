import XCTest
@testable import Jetty

final class AutoURLTests: XCTestCase {
    func testDetectsHTTP() {
        let s = Screen(cols: 40, rows: 2, scrollbackCapRows: 0)
        s.printRun("see https://example.com/x now")
        let hit = AutoURL.hover(screen: s, x: 10, y: 0, detect: true)
        XCTAssertEqual(hit?.url.host, "example.com")
        XCTAssertEqual(hit?.url.path, "/x")
        XCTAssertEqual(hit?.osc8, false)
        XCTAssertEqual(hit?.spans.first?.y, 0)
        XCTAssertEqual(hit?.spans.first?.x0, 4)
        XCTAssertNil(AutoURL.hover(screen: s, x: 0, y: 0, detect: true))
        XCTAssertNil(AutoURL.hover(screen: s, x: 10, y: 0, detect: false))
    }

    func testWrapJoinRemainder() {
        let s = Screen(cols: 20, rows: 3, scrollbackCapRows: 0)
        s.printRun("https://example.com/abc")
        XCTAssertTrue(s.isWrapped(0))
        let hit = AutoURL.hover(screen: s, x: 1, y: 1, detect: true)
        XCTAssertEqual(hit?.url.host, "example.com")
        XCTAssertEqual(hit?.url.path, "/abc")
        XCTAssertEqual(hit?.spans.count, 2)
        XCTAssertEqual(hit?.spans[0].y, 0)
        XCTAssertEqual(hit?.spans[1].y, 1)
        XCTAssertEqual(hit?.spans[1].x0, 0)
    }

    func testNoJoinWithoutWrap() {
        let s = Screen(cols: 40, rows: 3, scrollbackCapRows: 0)
        s.printRun("https://example.com")
        s.nel()
        s.printRun("abc")
        XCTAssertFalse(s.isWrapped(0))
        XCTAssertNil(AutoURL.hover(screen: s, x: 0, y: 1, detect: true))
        XCTAssertEqual(
            AutoURL.hover(screen: s, x: 0, y: 0, detect: true)?.url.host,
            "example.com"
        )
    }

    func testMailtoAndFileAndJavascript() {
        let s = Screen(cols: 40, rows: 4, scrollbackCapRows: 0)
        s.printRun("mailto:a@b.c")
        XCTAssertEqual(AutoURL.hover(screen: s, x: 0, y: 0, detect: true)?.url.scheme, "mailto")
        s.cup(row: 1, col: 0)
        s.printRun("file:///etc/passwd")
        XCTAssertNil(AutoURL.hover(screen: s, x: 0, y: 1, detect: true))
        s.cup(row: 2, col: 0)
        s.printRun("javascript:alert(1)")
        XCTAssertNil(AutoURL.hover(screen: s, x: 0, y: 2, detect: true))
    }

    func testOSC8WinsOverVisibleURL() {
        let s = Screen(cols: 40, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]8;;https://osc8.example\u{07}https://visible.example\u{1B}]8;;\u{07}")
        let hit = AutoURL.hover(screen: s, x: 2, y: 0, detect: true)
        XCTAssertEqual(hit?.url.host, "osc8.example")
        XCTAssertEqual(hit?.osc8, true)
    }

    func testOSC8DeniedDoesNotFallBackToDetector() {
        let s = Screen(cols: 40, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]8;;javascript:alert(1)\u{07}https://visible.example\u{1B}]8;;\u{07}")
        XCTAssertNil(AutoURL.hover(screen: s, x: 2, y: 0, detect: true))
    }

    func testOSC8WorksWhenDetectOff() {
        let s = Screen(cols: 20, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]8;;https://osc8.example\u{07}plain\u{1B}]8;;\u{07}")
        let hit = AutoURL.hover(screen: s, x: 0, y: 0, detect: false)
        XCTAssertEqual(hit?.url.host, "osc8.example")
        XCTAssertEqual(hit?.osc8, true)
    }

    func testHistoryRow() {
        let s = Screen(cols: 20, rows: 2, scrollbackCapRows: 4)
        s.printRun("https://example.com")
        s.index()
        s.index()
        XCTAssertGreaterThan(s.viewportHistoryCount, 0)
        let hit = AutoURL.hover(screen: s, x: 0, y: -1, detect: true)
        XCTAssertEqual(hit?.url.host, "example.com")
        XCTAssertEqual(hit?.spans.first?.y, -1)
    }
}
