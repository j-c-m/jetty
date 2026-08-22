import XCTest
@testable import Jetty

final class ScrollPhysicsTests: XCTestCase {
    func testPageImpulseMovesTowardHistory() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        XCTAssertTrue(p.pinnedToBottom)
        p.applyPageImpulse(direction: 1, holdCount: 1, viewportRows: 20)
        XCTAssertFalse(p.pinnedToBottom)
        XCTAssertTrue(p.step(dt: 1.0 / 60.0, maxOffset: 100, viewportRows: 20))
        XCTAssertLessThan(p.position, 100)
    }

    func testCmdEndSeeksBottom() {
        let p = ScrollPhysics()
        p.pinTop(maxOffset: 80)
        p.seekExtreme(direction: -1, holdCount: 1, viewportRows: 20, maxOffset: 80)
        XCTAssertTrue(p.isSeekingBottom)
        var n = 0
        while n < 120, p.step(dt: 1.0 / 60.0, maxOffset: 80, viewportRows: 20) {
            n += 1
        }
        XCTAssertTrue(p.pinnedToBottom)
        XCTAssertEqual(p.position, 80, accuracy: 0.05)
    }

    func testDoesNotOverscroll() {
        let p = ScrollPhysics()
        p.pinTop(maxOffset: 50)
        p.applyPageImpulse(direction: 1, holdCount: 8, viewportRows: 20)
        for _ in 0..<60 {
            _ = p.step(dt: 1.0 / 60.0, maxOffset: 50, viewportRows: 20)
            XCTAssertGreaterThanOrEqual(p.position, 0)
            XCTAssertLessThanOrEqual(p.position, 50)
        }
        p.pinBottom(maxOffset: 50)
        p.applyPageImpulse(direction: -1, holdCount: 8, viewportRows: 20)
        for _ in 0..<60 {
            _ = p.step(dt: 1.0 / 60.0, maxOffset: 50, viewportRows: 20)
            XCTAssertGreaterThanOrEqual(p.position, 0)
            XCTAssertLessThanOrEqual(p.position, 50)
        }
    }

    func testCmdHomeSeeksTop() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 80)
        p.seekExtreme(direction: 1, holdCount: 1, viewportRows: 20, maxOffset: 80)
        var n = 0
        while n < 120, p.step(dt: 1.0 / 60.0, maxOffset: 80, viewportRows: 20) {
            n += 1
        }
        XCTAssertFalse(p.pinnedToBottom)
        XCTAssertEqual(p.position, 0, accuracy: 0.05)
    }
}
