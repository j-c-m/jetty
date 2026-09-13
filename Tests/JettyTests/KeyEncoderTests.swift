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

    func testBackspaceDefaultIsDEL() {
        let event = keyEvent(flags: [], characters: "\u{08}", ignoring: "\u{08}", keyCode: kVK_Delete)
        XCTAssertEqual(XtermKeyEncoder.bytes(for: event, options: .init()), [0x7F])
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: event, options: .init(backarrow: true)),
            [0x08]
        )
        let ctrl = keyEvent(flags: .control, characters: "\u{08}", ignoring: "\u{08}", keyCode: kVK_Delete)
        XCTAssertEqual(XtermKeyEncoder.bytes(for: ctrl, options: .init()), [0x08])
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: ctrl, options: .init(backarrow: true)),
            [0x7F]
        )
    }

    func testAltSendsEscapeOffUsesCharacters() {
        let event = keyEvent(flags: .option, characters: "é", ignoring: "e", keyCode: kVK_ANSI_E)
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: event, options: .init(altSendsEscape: false)),
            Array("é".utf8)
        )
        XCTAssertFalse(XtermKeyEncoder.insertTextDefersToEncoder(
            composing: false, event: event, altSendsEscape: false
        ))
        let mok = XtermKeyEncoder.Options(modifyOtherKeys: 2, altSendsEscape: false)
        XCTAssertEqual(XtermKeyEncoder.bytes(for: event, options: mok), Array("é".utf8))
    }

    func testModifyOtherKeysCSI27() {
        let opts = XtermKeyEncoder.Options(modifyOtherKeys: 2)
        let ctrlP = keyEvent(flags: .control, characters: "\u{10}", ignoring: "p", keyCode: kVK_ANSI_P)
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: ctrlP, options: opts),
            Array("\u{1B}[27;5;112~".utf8)
        )
        let ctrlShiftH = keyEvent(
            flags: [.control, .shift], characters: "H", ignoring: "h", keyCode: kVK_ANSI_H
        )
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: ctrlShiftH, options: opts),
            Array("\u{1B}[27;6;72~".utf8)
        )
        let altE = keyEvent(flags: .option, characters: "é", ignoring: "e", keyCode: kVK_ANSI_E)
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: altE, options: opts),
            Array("\u{1B}[27;3;101~".utf8)
        )
        let shiftSpace = keyEvent(flags: .shift, characters: " ", ignoring: " ", keyCode: kVK_Space)
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: shiftSpace, options: opts),
            Array("\u{1B}[27;2;32~".utf8)
        )
        XCTAssertTrue(XtermKeyEncoder.insertTextDefersToEncoder(
            composing: false, event: ctrlP, modifyOtherKeys: 2
        ))
        XCTAssertTrue(XtermKeyEncoder.insertTextDefersToEncoder(
            composing: false, event: shiftSpace, modifyOtherKeys: 2
        ))
        let shiftTab = keyEvent(flags: .shift, characters: "\t", ignoring: "\t", keyCode: kVK_Tab)
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: shiftTab, options: opts),
            Array("\u{1B}[27;2;9~".utf8)
        )
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: shiftTab, applicationCursor: false),
            [0x1B, 0x5B, 0x5A]
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
