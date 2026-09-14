import XCTest
@testable import Jetty

final class ProgressInkTests: XCTestCase {
    func testPaletteIndex() {
        XCTAssertEqual(ProgressInk.paletteIndex(state: 1, percent: 40), 4)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 1, percent: 255), 4)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 3, percent: 255), 4)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 2, percent: 80), 1)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 2, percent: 100), 1)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 4, percent: 50), 3)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 4, percent: 100), 3)
        XCTAssertEqual(ProgressInk.paletteIndex(state: 1, percent: 100), 2)
    }
}

final class ProgressPulseTests: XCTestCase {
    func testIndeterminateStates() {
        XCTAssertFalse(ProgressPulse.isIndeterminate(state: 0, percent: 255))
        XCTAssertTrue(ProgressPulse.isIndeterminate(state: 1, percent: 255))
        XCTAssertTrue(ProgressPulse.isIndeterminate(state: 2, percent: 255))
        XCTAssertTrue(ProgressPulse.isIndeterminate(state: 3, percent: 0))
        XCTAssertTrue(ProgressPulse.isIndeterminate(state: 3, percent: 50))
        XCTAssertFalse(ProgressPulse.isIndeterminate(state: 1, percent: 40))
        XCTAssertFalse(ProgressPulse.isIndeterminate(state: 4, percent: 255))
        XCTAssertFalse(ProgressPulse.isIndeterminate(state: 4, percent: 50))
        XCTAssertFalse(ProgressPulse.isIndeterminate(state: 5, percent: 255))
    }

    func testStaleTimeoutMatchesGhostty() {
        XCTAssertEqual(ProgressPulse.staleTimeout, 15)
    }

    func testBreathKeepsBarVisible() {
        XCTAssertGreaterThan(ProgressPulse.alphaMin, 0)
        XCTAssertLessThan(ProgressPulse.alphaMin, ProgressPulse.alphaMax)
        XCTAssertEqual(ProgressPulse.alphaMax, 1)
        XCTAssertEqual(ProgressPulse.duration, 1.2)
    }

    func testSamplesAt20Hz() {
        XCTAssertEqual(ProgressPulse.hz, 20)
        XCTAssertEqual(ProgressPulse.interval, 0.05)
        XCTAssertEqual(ProgressPulse.cycleSteps, 48)
    }

    func testChromeFrameSitsAtGridTop() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(
            ProgressPulse.chromeFrame(bounds: bounds, flipped: false, safeTop: 0),
            CGRect(x: 0, y: 598, width: 800, height: 2)
        )
        XCTAssertEqual(
            ProgressPulse.chromeFrame(bounds: bounds, flipped: true, safeTop: 0),
            CGRect(x: 0, y: 0, width: 800, height: 2)
        )
        XCTAssertEqual(
            ProgressPulse.chromeFrame(bounds: bounds, flipped: false, safeTop: 28),
            CGRect(x: 0, y: 570, width: 800, height: 2)
        )
    }

    func testOpacityPeaksAndTroughs() {
        XCTAssertEqual(ProgressPulse.opacity(step: 0), ProgressPulse.alphaMax)
        XCTAssertEqual(
            ProgressPulse.opacity(step: ProgressPulse.cycleSteps / 2),
            ProgressPulse.alphaMin,
            accuracy: 0.0001
        )
        XCTAssertEqual(ProgressPulse.advance(step: ProgressPulse.cycleSteps - 1), 0)
        XCTAssertNotEqual(ProgressPulse.opacity(step: 0), ProgressPulse.opacity(step: 1))
    }
}
