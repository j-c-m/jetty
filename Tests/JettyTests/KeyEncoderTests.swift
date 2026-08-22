import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Jetty

final class LinkURLTests: XCTestCase {
    func testAllowHTTPAndMailto() {
        XCTAssertNotNil(LinkURL.openable("https://example.com/x"))
        XCTAssertNotNil(LinkURL.openable("mailto:a@b.c"))
        XCTAssertNil(LinkURL.openable("file:///etc/passwd"))
        XCTAssertNil(LinkURL.openable("javascript:alert(1)"))
        XCTAssertNil(LinkURL.openable("https://"))
        XCTAssertNil(LinkURL.openable("\u{202A}https://example.com"))
    }
}

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

    func testIMEShouldEncodeKeyDown() {
        XCTAssertTrue(XtermKeyEncoder.shouldEncodeKeyDown(
            hasMarkedText: false, wasMarked: false, insertTextConsumed: false
        ))
        XCTAssertFalse(XtermKeyEncoder.shouldEncodeKeyDown(
            hasMarkedText: true, wasMarked: false, insertTextConsumed: false
        ))
        XCTAssertFalse(XtermKeyEncoder.shouldEncodeKeyDown(
            hasMarkedText: false, wasMarked: true, insertTextConsumed: false
        ))
        XCTAssertFalse(XtermKeyEncoder.shouldEncodeKeyDown(
            hasMarkedText: false, wasMarked: false, insertTextConsumed: true
        ))
    }

    func testIMEInsertTextDefersToEncoder() {
        let opt = keyEvent(flags: .option, characters: "é", ignoring: "e", keyCode: kVK_ANSI_E)
        XCTAssertTrue(XtermKeyEncoder.insertTextDefersToEncoder(composing: false, event: opt))
        XCTAssertFalse(XtermKeyEncoder.insertTextDefersToEncoder(composing: true, event: opt))
        let shiftRet = keyEvent(flags: .shift, characters: "\r", ignoring: "\r", keyCode: kVK_Return)
        XCTAssertTrue(XtermKeyEncoder.insertTextDefersToEncoder(composing: false, event: shiftRet))
        XCTAssertFalse(XtermKeyEncoder.insertTextDefersToEncoder(composing: true, event: shiftRet))
        let ret = keyEvent(flags: [], characters: "\r", ignoring: "\r", keyCode: kVK_Return)
        XCTAssertFalse(XtermKeyEncoder.insertTextDefersToEncoder(composing: false, event: ret))
    }

    func testEnterIsCR() {
        let event = keyEvent(flags: [], characters: "\r", ignoring: "\r", keyCode: kVK_Return)
        XCTAssertEqual(XtermKeyEncoder.bytes(for: event, applicationCursor: false), [0x0D])
    }

    func testShiftEnterIsLF() {
        let event = keyEvent(flags: .shift, characters: "\r", ignoring: "\r", keyCode: kVK_Return)
        XCTAssertEqual(XtermKeyEncoder.bytes(for: event, applicationCursor: false), [0x0A])
        let pad = keyEvent(flags: .shift, characters: "\r", ignoring: "\r", keyCode: kVK_ANSI_KeypadEnter)
        XCTAssertEqual(XtermKeyEncoder.bytes(for: pad, applicationCursor: false), [0x0A])
    }

    func testIMECommittedUTF8() {
        XCTAssertEqual(XtermKeyEncoder.committedUTF8("a\nb", composing: false), [0x61, 0x0D, 0x62])
        XCTAssertNil(XtermKeyEncoder.committedUTF8("\n", composing: true))
        XCTAssertNil(XtermKeyEncoder.committedUTF8("", composing: false))
        XCTAssertEqual(XtermKeyEncoder.committedUTF8("é", composing: true), Array("é".utf8))
        XCTAssertEqual(XtermKeyEncoder.committedUTF8("中", composing: true), Array("中".utf8))
    }

    func testOptionASCIIIsMeta() {
        let event = keyEvent(flags: .option, characters: "é", ignoring: "e", keyCode: kVK_ANSI_E)
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: event, applicationCursor: false),
            [0x1B, UInt8(ascii: "e")]
        )
    }

    private func keyEvent(
        flags: NSEvent.ModifierFlags,
        characters: String,
        ignoring: String,
        keyCode: Int
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }
}
