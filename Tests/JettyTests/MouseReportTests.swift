import XCTest
@testable import Jetty

final class MouseReportTests: XCTestCase {
    func testX10Packet() {
        let p = X10Mouse.packet(button: 0, x: 1, y: 2)
        XCTAssertEqual(p, [0x1B, 0x5B, 0x4D, 32, 33, 34])
    }

    func testSGRPressRelease() {
        let down = SGRMouse.packet(button: 0, x: 5, y: 9)
        XCTAssertEqual(String(bytes: down, encoding: .utf8), "\u{1B}[<0;5;9M")
        let up = SGRMouse.packet(button: 2, x: 5, y: 9, release: true)
        XCTAssertEqual(String(bytes: up, encoding: .utf8), "\u{1B}[<2;5;9m")
    }

    func testSGRMotionAndWheel() {
        let move = SGRMouse.packet(button: 0, x: 2, y: 3, motion: true)
        XCTAssertEqual(String(bytes: move, encoding: .utf8), "\u{1B}[<32;2;3M")
        let wheel = SGRMouse.packet(button: 64, x: 1, y: 1)
        XCTAssertEqual(String(bytes: wheel, encoding: .utf8), "\u{1B}[<64;1;1M")
    }

    func testShouldReportModes() {
        XCTAssertFalse(MouseReport.shouldReport(mode: 0, action: .press, button: 0))
        XCTAssertTrue(MouseReport.shouldReport(mode: 9, action: .press, button: 0))
        XCTAssertFalse(MouseReport.shouldReport(mode: 9, action: .release, button: 0))
        XCTAssertFalse(MouseReport.shouldReport(mode: 9, action: .press, button: 64))
        XCTAssertTrue(MouseReport.shouldReport(mode: 1000, action: .release, button: 0))
        XCTAssertFalse(MouseReport.shouldReport(mode: 1000, action: .motion, button: 0))
        XCTAssertTrue(MouseReport.shouldReport(mode: 1002, action: .motion, button: 0))
        XCTAssertFalse(MouseReport.shouldReport(mode: 1002, action: .motion, button: nil))
        XCTAssertTrue(MouseReport.shouldReport(mode: 1003, action: .motion, button: nil))
    }

    func testEncodeX10ReleaseIsButton3() {
        let p = MouseReport.packet(
            mode: 1000, sgr: false, action: .release, button: 0, x: 1, y: 1
        )
        XCTAssertEqual(p, X10Mouse.packet(button: 3, x: 1, y: 1))
    }

    func testEncodeSGRKeepsButtonOnRelease() {
        let p = MouseReport.packet(
            mode: 1000, sgr: true, action: .release, button: 2, x: 4, y: 8
        )
        XCTAssertEqual(String(bytes: p ?? [], encoding: .utf8), "\u{1B}[<2;4;8m")
    }

    func testX10OmitsModifiers() {
        let p = MouseReport.packet(
            mode: 9, sgr: false, action: .press, button: 0, x: 1, y: 1,
            shift: true, ctrl: true
        )
        XCTAssertEqual(p, X10Mouse.packet(button: 0, x: 1, y: 1))
    }
}
