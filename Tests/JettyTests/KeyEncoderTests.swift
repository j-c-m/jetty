import AppKit
import Carbon.HIToolbox
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

    func testIMEInsertTextDefersToMeta() {
        XCTAssertTrue(XtermKeyEncoder.insertTextDefersToMeta(composing: false, option: true))
        XCTAssertFalse(XtermKeyEncoder.insertTextDefersToMeta(composing: true, option: true))
        XCTAssertFalse(XtermKeyEncoder.insertTextDefersToMeta(composing: false, option: false))
    }

    func testIMECommittedUTF8() {
        XCTAssertEqual(XtermKeyEncoder.committedUTF8("a\nb", composing: false), [0x61, 0x0D, 0x62])
        XCTAssertNil(XtermKeyEncoder.committedUTF8("\n", composing: true))
        XCTAssertNil(XtermKeyEncoder.committedUTF8("", composing: false))
        XCTAssertEqual(XtermKeyEncoder.committedUTF8("é", composing: true), Array("é".utf8))
        XCTAssertEqual(XtermKeyEncoder.committedUTF8("中", composing: true), Array("中".utf8))
    }

    func testOptionASCIIIsMeta() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "é",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_E)
        ) else {
            XCTFail("NSEvent")
            return
        }
        XCTAssertEqual(
            XtermKeyEncoder.bytes(for: event, applicationCursor: false),
            [0x1B, UInt8(ascii: "e")]
        )
    }
}
