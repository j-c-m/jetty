import AppKit
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

    func testPasteboardPayloadPrefersFileURL() {
        let pb = NSPasteboard(name: .init("jetty.test.pasteboard.files"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/foo bar") as NSURL])
        XCTAssertEqual(Clipboard.pasteboardPayload(pb), "'/tmp/foo bar'")
    }

    func testPasteboardPayloadStringWhenNoFile() {
        let pb = NSPasteboard(name: .init("jetty.test.pasteboard.string"))
        pb.clearContents()
        pb.setString("hello", forType: .string)
        XCTAssertEqual(Clipboard.pasteboardPayload(pb), "hello")
    }

    func testPngFromTIFF() {
        let img = NSImage(size: NSSize(width: 2, height: 2))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation else {
            XCTFail("tiff")
            return
        }
        XCTAssertNotNil(Clipboard.pngFromTIFF(tiff))
    }

    func testPasteEventsWinOverBracketedPaste() {
        let session = makeSession()
        session.parser.feed("\u{1B}[?5522h\u{1B}[?2004h")
        XCTAssertTrue(session.screen.pasteEvents)
        XCTAssertTrue(session.screen.bracketedPaste)
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let box = WriteBox()
        session.ptyWriteSink = { box.add($0) }
        session.pasteFromPasteboard(pb)
        let text = box.text()
        XCTAssertTrue(text.contains("5522;type=read:status=OK"))
        XCTAssertTrue(text.contains("5522;type=read:status=DATA:mime=Lg=="))
        XCTAssertTrue(text.contains("5522;type=read:status=DONE"))
        XCTAssertFalse(text.contains("[200~"))
    }

    func testPasteEventsDragDropSendsListingNotQuotedPath() {
        let session = makeSession()
        session.parser.feed("\u{1B}[?5522h\u{1B}[?2004h")
        let pb = namedPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/foo bar") as NSURL])
        let box = WriteBox()
        session.ptyWriteSink = { box.add($0) }
        XCTAssertTrue(session.dropFromPasteboard(pb))
        let text = box.text()
        XCTAssertTrue(text.contains("5522;type=read:status=OK"))
        XCTAssertFalse(text.contains("[200~"))
        XCTAssertFalse(text.contains("'/tmp/foo bar'"))
        XCTAssertFalse(text.contains("/tmp/foo bar"))
    }

    func testPasteEventsDenyKeepsHostPasteAndQuotedDrop() {
        let session = makeSession(ask: false)
        session.parser.feed("\u{1B}[?5522h\u{1B}[?2004h")
        XCTAssertFalse(session.screen.pasteEvents)
        XCTAssertTrue(session.screen.bracketedPaste)
        let textPb = namedPasteboard()
        textPb.setString("hello", forType: .string)
        let box = WriteBox()
        session.ptyWriteSink = { box.add($0) }
        session.pasteFromPasteboard(textPb)
        XCTAssertEqual(box.text(), "\u{1B}[200~hello\u{1B}[201~")

        let dropPb = namedPasteboard()
        dropPb.writeObjects([URL(fileURLWithPath: "/tmp/foo bar") as NSURL])
        box.clear()
        XCTAssertTrue(session.dropFromPasteboard(dropPb))
        XCTAssertEqual(box.text(), "\u{1B}[200~'/tmp/foo bar'\u{1B}[201~")
        XCTAssertFalse(box.text().contains("5522"))
    }

    func testPasteFallsBackToHostPasteWhileDataInFlight() {
        let session = makeSession()
        session.parser.feed("\u{1B}[?5522h\u{1B}[?2004h")
        session.dataReplyInFlight = true
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let box = WriteBox()
        session.ptyWriteSink = { box.add($0) }
        session.pasteFromPasteboard(pb)
        XCTAssertEqual(box.text(), "\u{1B}[200~hello\u{1B}[201~")
        XCTAssertFalse(box.text().contains("5522"))
    }

    func testDropFallsBackToQuotedPathWhileDataInFlight() {
        let session = makeSession()
        session.parser.feed("\u{1B}[?5522h\u{1B}[?2004h")
        session.dataReplyInFlight = true
        let pb = namedPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/foo bar") as NSURL])
        let box = WriteBox()
        session.ptyWriteSink = { box.add($0) }
        XCTAssertTrue(session.dropFromPasteboard(pb))
        XCTAssertEqual(box.text(), "\u{1B}[200~'/tmp/foo bar'\u{1B}[201~")
        XCTAssertFalse(box.text().contains("5522"))
    }

    func testLiveDenyClearsPasteEventsAndHostPastes() {
        let session = makeSession()
        session.parser.feed("\u{1B}[?5522h\u{1B}[?2004h")
        XCTAssertTrue(session.screen.pasteEvents)
        session.osc52ReadAsk = false
        session.screen.setOsc52ReadAsk(false)
        XCTAssertFalse(session.screen.pasteEvents)
        session.parser.writes.removeAll()
        session.parser.feed("\u{1B}[?5522$p")
        XCTAssertEqual(String(bytes: session.parser.writes, encoding: .utf8), "\u{1B}[?5522;0$y")
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let box = WriteBox()
        session.ptyWriteSink = { box.add($0) }
        session.pasteFromPasteboard(pb)
        XCTAssertEqual(box.text(), "\u{1B}[200~hello\u{1B}[201~")
    }

    private func makeSession(ask: Bool = true) -> TerminalSession {
        let session = TerminalSession(
            cols: 10, rows: 2, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0
        )
        session.osc52ReadAsk = ask
        session.screen.setOsc52ReadAsk(ask)
        return session
    }

    private func namedPasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("jetty.test.clipboard.\(UUID().uuidString)"))
    }

    private final class WriteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []
        func add(_ p: [UInt8]) {
            lock.lock()
            packets.append(p)
            lock.unlock()
        }
        func clear() {
            lock.lock()
            packets.removeAll()
            lock.unlock()
        }
        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(bytes: packets.flatMap { $0 }, encoding: .utf8) ?? ""
        }
    }
}
