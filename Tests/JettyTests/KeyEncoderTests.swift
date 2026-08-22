import XCTest
@testable import Jetty

final class KeyEncoderTests: XCTestCase {
    func testAlternateScrollCSI() {
        var pending = 0.0
        let up = XtermKeyEncoder.alternateScroll(
            deltaRows: 2,
            pending: &pending,
            applicationCursor: false
        )
        XCTAssertEqual(up, [0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x41])
        XCTAssertEqual(pending, 0)

        let down = XtermKeyEncoder.alternateScroll(
            deltaRows: -1,
            pending: &pending,
            applicationCursor: true
        )
        XCTAssertEqual(down, [0x1B, 0x4F, 0x42])
    }

    func testAlternateScrollRemainder() {
        var pending = 0.0
        XCTAssertNil(XtermKeyEncoder.alternateScroll(
            deltaRows: 0.4,
            pending: &pending,
            applicationCursor: false
        ))
        XCTAssertEqual(pending, 0.4, accuracy: 1e-9)
        let keys = XtermKeyEncoder.alternateScroll(
            deltaRows: 0.7,
            pending: &pending,
            applicationCursor: false
        )
        XCTAssertEqual(keys, [0x1B, 0x5B, 0x41])
        XCTAssertEqual(pending, 0.1, accuracy: 1e-9)
    }
}
