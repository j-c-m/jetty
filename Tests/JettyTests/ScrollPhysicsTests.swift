import XCTest
@testable import Jetty

final class ScrollPhysicsTests: XCTestCase {
    func testPageImpulseMovesTowardHistory() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        XCTAssertTrue(p.pinnedToBottom)
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        XCTAssertFalse(p.pinnedToBottom)
        XCTAssertTrue(p.step(dt: 1.0 / 60.0, maxOffset: 100, viewportRows: 20))
        XCTAssertLessThan(p.position, 100)
    }

    func testPageImpulseCoastsAboutOneViewportAtLowFriction() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 400)
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        var n = 0
        while n < 300, p.step(dt: 1.0 / 60.0, maxOffset: 400, viewportRows: 20) {
            n += 1
        }
        XCTAssertEqual(p.position, 381)
        XCTAssertEqual(p.integerRow(maxOffset: 400), 381)
    }

    func testPageImpulseRepeatAddsAnotherViewportKick() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 400)
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        _ = p.step(dt: 1.0 / 60.0, maxOffset: 400, viewportRows: 20)
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        var n = 0
        while n < 120, p.step(dt: 1.0 / 60.0, maxOffset: 400, viewportRows: 20) {
            n += 1
        }
        XCTAssertEqual(p.position, 362)
    }

    func testPageImpulseSurvivesZeroDt() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 400)
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        XCTAssertTrue(p.step(dt: 0, maxOffset: 400, viewportRows: 20))
        XCTAssertFalse(p.pinnedToBottom)
        XCTAssertNotEqual(p.velocity, 0)
        XCTAssertEqual(p.position, 400)
    }

    func testPageImpulseSurvivesSubMsFromBottom() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 400)
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        XCTAssertTrue(p.step(dt: 0.0001, maxOffset: 400, viewportRows: 20))
        XCTAssertFalse(p.pinnedToBottom)
        XCTAssertNotEqual(p.velocity, 0)
    }

    func testTrimTopShiftsSeekTarget() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 20, ended: true)
        XCTAssertEqual(p.position, 80, accuracy: 1e-9)
        p.smoothTo(offset: 50, maxOffset: 100)
        p.trimTop(10)
        XCTAssertEqual(p.position, 70, accuracy: 1e-9)
        var n = 0
        while n < 240, p.step(dt: 1.0 / 60.0, maxOffset: 90, viewportRows: 20) {
            n += 1
        }
        XCTAssertEqual(p.position, 40, accuracy: 0.25)
        XCTAssertFalse(p.pinnedToBottom)
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
        p.applyPageImpulse(direction: 1, viewportRows: 20)
        for _ in 0..<60 {
            _ = p.step(dt: 1.0 / 60.0, maxOffset: 50, viewportRows: 20)
            XCTAssertGreaterThanOrEqual(p.position, 0)
            XCTAssertLessThanOrEqual(p.position, 50)
        }
        p.pinBottom(maxOffset: 50)
        p.applyPageImpulse(direction: -1, viewportRows: 20)
        for _ in 0..<60 {
            _ = p.step(dt: 1.0 / 60.0, maxOffset: 50, viewportRows: 20)
            XCTAssertGreaterThanOrEqual(p.position, 0)
            XCTAssertLessThanOrEqual(p.position, 50)
        }
    }

    func testWheelImpulseCoastsAboutTheDelta() {
        let p = ScrollPhysics()
        var t = 0.0
        p.now = { t }
        p.pinBottom(maxOffset: 500)
        t = 0.1
        XCTAssertFalse(p.step(dt: 1.0 / 60.0, maxOffset: 500, viewportRows: 35))
        t = 1.0
        p.applyImpulse(deltaRows: 8)
        t = 1.05
        XCTAssertTrue(p.step(dt: 0.05, maxOffset: 500, viewportRows: 35))
        var n = 0
        while n < 400, p.step(dt: 1.0 / 60.0, maxOffset: 500, viewportRows: 35) {
            n += 1
            t += 1.0 / 60.0
        }
        XCTAssertEqual(p.position, 492, accuracy: 0.25)
        XCTAssertFalse(p.pinnedToBottom)
    }

    func testPreciseDeltaMovesOneToOne() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 5, ended: false)
        XCTAssertEqual(p.position, 95, accuracy: 1e-9)
        XCTAssertFalse(p.pinnedToBottom)
    }

    func testPreciseDeltaDoesNotIntegrateWhileFingersDown() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 2, ended: false)
        p.applyPreciseDelta(deltaRows: 2, ended: false)
        let pos = p.position
        XCTAssertFalse(p.step(dt: 1.0 / 60.0, maxOffset: 100, viewportRows: 20))
        XCTAssertEqual(p.position, pos, accuracy: 1e-9)
    }

    func testBrakeStopsCoast() {
        let p = ScrollPhysics()
        p.maxRowsPerFrame = 1_000
        p.pinBottom(maxOffset: 400)
        p.applyImpulse(deltaRows: 8)
        XCTAssertTrue(p.step(dt: 1.0 / 60.0, maxOffset: 400, viewportRows: 20))
        let pos = p.position
        p.brake()
        XCTAssertFalse(p.step(dt: 1.0 / 60.0, maxOffset: 400, viewportRows: 20))
        XCTAssertEqual(p.position, pos, accuracy: 1e-9)
        XCTAssertFalse(p.pinnedToBottom)
    }

    func testPreciseDeltaDoesNotCoastAfterEnded() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 400)
        p.applyPreciseDelta(deltaRows: 1, ended: false)
        p.applyPreciseDelta(deltaRows: 1, ended: false)
        p.applyPreciseDelta(deltaRows: 0, ended: true)
        let pos = p.position
        XCTAssertFalse(p.step(dt: 1.0 / 60.0, maxOffset: 400, viewportRows: 20))
        XCTAssertEqual(p.position, pos, accuracy: 1e-9)
    }

    func testMomentumDeltaMovesOneToOne() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 2, ended: true)
        XCTAssertEqual(p.position, 98, accuracy: 1e-9)
        p.applyPreciseDelta(deltaRows: 3, ended: false, momentum: true)
        XCTAssertEqual(p.position, 95, accuracy: 1e-9)
        XCTAssertFalse(p.step(dt: 1.0 / 60.0, maxOffset: 100, viewportRows: 20))
        XCTAssertEqual(p.position, 95, accuracy: 1e-9)
    }

    func testMomentumIgnoredAfterPin() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 10, ended: true)
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 5, ended: false, momentum: true)
        XCTAssertEqual(p.position, 100, accuracy: 1e-9)
        XCTAssertTrue(p.pinnedToBottom)
    }

    func testFingerDeltaClearsMomentumIgnore() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 1, ended: false, momentum: true)
        XCTAssertEqual(p.position, 100, accuracy: 1e-9)
        p.applyPreciseDelta(deltaRows: 4, ended: false)
        XCTAssertEqual(p.position, 96, accuracy: 1e-9)
        XCTAssertFalse(p.pinnedToBottom)
    }

    func testImpulseIgnoresLaterMomentum() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 500)
        p.applyImpulse(deltaRows: 8)
        let pos = p.position
        XCTAssertNotEqual(p.velocity, 0)
        p.applyPreciseDelta(deltaRows: 20, ended: false, momentum: true)
        XCTAssertEqual(p.position, pos, accuracy: 1e-9)
        XCTAssertNotEqual(p.velocity, 0)
    }

    func testPrecisionWheelTickDoesNotCoast() {
        let p = ScrollPhysics()
        p.pinBottom(maxOffset: 100)
        p.applyPreciseDelta(deltaRows: 2.5, ended: true)
        XCTAssertEqual(p.position, 97.5, accuracy: 1e-9)
        XCTAssertFalse(p.step(dt: 1.0 / 60.0, maxOffset: 100, viewportRows: 20))
        XCTAssertEqual(p.position, 97.5, accuracy: 1e-9)
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
