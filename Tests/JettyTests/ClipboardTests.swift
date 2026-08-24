import XCTest
@testable import Jetty

final class ClipboardTests: XCTestCase {
    func testPasteUnbracketedIsIdentity() {
        let raw = Array("hello\nworld\u{1B}[201~x".utf8)
        XCTAssertEqual(Clipboard.pasteBytes(raw, bracketed: false), raw)
    }

    func testPasteBracketedWraps() {
        let out = Clipboard.pasteBytes(Array("hi".utf8), bracketed: true)
        XCTAssertEqual(String(bytes: out, encoding: .utf8), "\u{1B}[200~hi\u{1B}[201~")
    }

    func testPasteBracketedStripsNestedEnd() {
        let raw = Array("a\u{1B}[201~b\u{1B}[201~c".utf8)
        let out = Clipboard.pasteBytes(raw, bracketed: true)
        XCTAssertEqual(String(bytes: out, encoding: .utf8), "\u{1B}[200~abc\u{1B}[201~")
    }

    func testPasteBracketedEmptyStillWraps() {
        let out = Clipboard.pasteBytes([], bracketed: true)
        XCTAssertEqual(out, Clipboard.pasteStart + Clipboard.pasteEnd)
    }

    func testFocusPackets() {
        XCTAssertEqual(Clipboard.focusBytes(gained: true), [0x1B, 0x5B, 0x49])
        XCTAssertEqual(Clipboard.focusBytes(gained: false), [0x1B, 0x5B, 0x4F])
    }

    func testPosixQuote() {
        XCTAssertEqual(Clipboard.posixQuote(""), "''")
        XCTAssertEqual(Clipboard.posixQuote("/tmp/foo"), "'/tmp/foo'")
        XCTAssertEqual(Clipboard.posixQuote("/tmp/foo bar"), "'/tmp/foo bar'")
        XCTAssertEqual(Clipboard.posixQuote("/tmp/it's"), "'/tmp/it'\\''s'")
    }

    func testDroppedPathsJoinQuoted() {
        XCTAssertEqual(
            Clipboard.droppedPaths(["/a b", "/c"]),
            "'/a b' '/c'"
        )
    }
}
