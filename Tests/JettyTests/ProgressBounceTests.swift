import XCTest
@testable import Jetty

final class ProgressBounceTests: XCTestCase {
    func testAdvanceStepsAndReverses() {
        let a = ProgressBounce.advance(pos: 0, dir: 1)
        XCTAssertEqual(a.pos, ProgressBounce.step)
        XCTAssertEqual(a.dir, 1)

        let b = ProgressBounce.advance(pos: 1 - ProgressBounce.step / 2, dir: 1)
        XCTAssertEqual(b.pos, 1)
        XCTAssertEqual(b.dir, -1)

        let c = ProgressBounce.advance(pos: 1, dir: -1)
        XCTAssertEqual(c.pos, 1 - ProgressBounce.step)
        XCTAssertEqual(c.dir, -1)

        let d = ProgressBounce.advance(pos: ProgressBounce.step / 2, dir: -1)
        XCTAssertEqual(d.pos, 0)
        XCTAssertEqual(d.dir, 1)
    }

    func testStaleTimeoutMatchesGhostty() {
        XCTAssertEqual(ProgressBounce.staleTimeout, 15)
    }

    func testTickIntervalReduceMotionIs1Hz() {
        XCTAssertEqual(ProgressBounce.tickInterval(reduceMotion: false), 0.125)
        XCTAssertEqual(ProgressBounce.tickInterval(reduceMotion: true), 1)
    }

    func testFillFrameTravel() {
        let h: CGFloat = 2
        XCTAssertEqual(
            ProgressBounce.fillFrame(width: 100, height: h, pos: 0),
            CGRect(x: 0, y: 0, width: 25, height: h)
        )
        XCTAssertEqual(
            ProgressBounce.fillFrame(width: 100, height: h, pos: 1),
            CGRect(x: 75, y: 0, width: 25, height: h)
        )
        XCTAssertEqual(
            ProgressBounce.fillFrame(width: 100, height: h, pos: 0.5),
            CGRect(x: 37.5, y: 0, width: 25, height: h)
        )
        XCTAssertEqual(
            ProgressBounce.fillFrame(width: 0, height: h, pos: 1),
            CGRect(x: 0, y: 0, width: 0, height: h)
        )
    }
}
