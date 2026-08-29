import XCTest
@testable import Jetty

final class PromptJumpTests: XCTestCase {
    func testUsesAPLIgnoresCD() {
        let marks: [(UInt64, UInt8)] = [
            (2, UInt8(ascii: "C")),
            (4, UInt8(ascii: "A")),
            (8, UInt8(ascii: "D")),
            (12, UInt8(ascii: "P")),
            (16, UInt8(ascii: "L")),
        ]
        XCTAssertEqual(
            PromptJump.target(
                marks: marks, dir: 1, linesScrolled: 0, sbLen: 0, rows: 20, integerRow: 0
            ),
            4
        )
        XCTAssertEqual(
            PromptJump.target(
                marks: marks, dir: 1, linesScrolled: 0, sbLen: 0, rows: 20, integerRow: 4
            ),
            12
        )
        XCTAssertEqual(
            PromptJump.target(
                marks: marks, dir: -1, linesScrolled: 0, sbLen: 0, rows: 20, integerRow: 16
            ),
            12
        )
    }

    func testSkipsExpiredDoesNotClampToZero() {
        let marks: [(UInt64, UInt8)] = [
            (0, UInt8(ascii: "A")),
            (8, UInt8(ascii: "A")),
            (16, UInt8(ascii: "A")),
        ]
        let prev = PromptJump.target(
            marks: marks, dir: -1, linesScrolled: 15, sbLen: 10, rows: 5, integerRow: 5
        )
        XCTAssertEqual(prev, 8)
        XCTAssertNotEqual(prev, 0)
        XCTAssertNil(
            PromptJump.target(
                marks: marks, dir: -1, linesScrolled: 15, sbLen: 10, rows: 5, integerRow: 0
            )
        )
    }

    func testNoInWindowMarkIsNil() {
        let marks: [(UInt64, UInt8)] = [(100, UInt8(ascii: "A"))]
        XCTAssertNil(
            PromptJump.target(
                marks: marks, dir: -1, linesScrolled: 0, sbLen: 0, rows: 10, integerRow: 0
            )
        )
    }

    func testDocRowMapsHistoryAndLive() {
        XCTAssertEqual(PromptJump.docRow(line: 5, linesScrolled: 15, sbLen: 10), 0)
        XCTAssertEqual(PromptJump.docRow(line: 8, linesScrolled: 15, sbLen: 10), 3)
        XCTAssertEqual(PromptJump.docRow(line: 15, linesScrolled: 15, sbLen: 10), 10)
    }
}

final class Osc133StoreTests: XCTestCase {
    func testIgnoresOsc133InAlt() {
        let s = TerminalSession(cols: 10, rows: 3, scrollbackCapRows: 8)
        s.lock.lock()
        s.screen.switchScreenMode(1049, enabled: true)
        s.parser.feed("\u{1B}]133;A\u{07}")
        XCTAssertTrue(s.osc133.isEmpty)
        s.screen.switchScreenMode(1049, enabled: false)
        s.parser.feed("\u{1B}]133;A\u{07}")
        XCTAssertEqual(s.osc133.count, 1)
        XCTAssertEqual(s.osc133[0].action, UInt8(ascii: "A"))
        s.lock.unlock()
    }

    func testED3ClearsMarksKeepsLive() {
        let s = TerminalSession(cols: 4, rows: 2, scrollbackCapRows: 8)
        s.lock.lock()
        s.parser.feed("AAAA")
        s.parser.feed("\u{1B}]133;A\u{07}")
        XCTAssertEqual(s.osc133.count, 1)
        s.parser.feed("\u{1B}[3J")
        XCTAssertTrue(s.osc133.isEmpty)
        XCTAssertEqual(s.screen.scrollbackCount, 0)
        XCTAssertEqual(s.screen.glyph(0, 0), UInt32(UInt8(ascii: "A")))
        s.lock.unlock()
    }

    func testED3ClearsCommandTimer() {
        let s = TerminalSession(cols: 4, rows: 2, scrollbackCapRows: 8)
        s.lock.lock()
        s.parser.feed("\u{1B}]133;C\u{07}")
        XCTAssertNotNil(s.commandStartedAt)
        s.parser.feed("\u{1B}[3J")
        XCTAssertNil(s.commandStartedAt)
        s.lock.unlock()
    }

    func testRISClearsMarksAndScrollback() {
        let s = TerminalSession(cols: 4, rows: 2, scrollbackCapRows: 8)
        s.lock.lock()
        s.parser.feed("AAAABBBBCCCC")
        s.parser.feed("\u{1B}]133;A\u{07}")
        s.parser.feed("\u{1B}]133;C\u{07}")
        XCTAssertGreaterThan(s.screen.scrollbackCount, 0)
        XCTAssertEqual(s.osc133.count, 2)
        XCTAssertNotNil(s.commandStartedAt)
        s.parser.feed("\u{1B}c")
        XCTAssertTrue(s.osc133.isEmpty)
        XCTAssertNil(s.commandStartedAt)
        XCTAssertEqual(s.screen.scrollbackCount, 0)
        s.lock.unlock()
    }

    func testED2DoesNotClearMarks() {
        let s = TerminalSession(cols: 10, rows: 2, scrollbackCapRows: 0)
        s.lock.lock()
        s.parser.feed("\u{1B}]133;A\u{07}")
        s.parser.feed("\u{1B}[2J")
        XCTAssertEqual(s.osc133.count, 1)
        s.lock.unlock()
    }
}
