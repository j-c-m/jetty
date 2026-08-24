import AppKit
import Carbon.HIToolbox
import CVt
import XCTest
@testable import Jetty

final class KeybindsTests: XCTestCase {
    func testParsesDesignExamples() {
        let t = Keybinds.Table(lines: [
            "cmd+shift+up=jump_to_prompt:-1",
            "cmd+shift+down=jump_to_prompt:1",
            "cmd+f=start_search",
            "cmd+g=find_next",
            "cmd+shift+g=find_prev",
            "cmd+shift+comma=reload_config",
        ])
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_UpArrow), flags: [.command, .shift]),
            .jumpToPrompt(-1)
        )
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_DownArrow), flags: [.command, .shift]),
            .jumpToPrompt(1)
        )
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_F), flags: .command),
            .startSearch
        )
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_G), flags: .command),
            .findNext
        )
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_G), flags: [.command, .shift]),
            .findPrev
        )
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_Comma), flags: [.command, .shift]),
            .reloadConfig
        )
    }

    func testUnknownAndPrefixedLinesIgnored() {
        let t = Keybinds.Table(lines: [
            "cmd+x=not_an_action",
            "global:cmd+c=copy",
            "cmd+shift+nope=copy",
            "cmd+c=copy",
        ])
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_C), flags: .command),
            .copy
        )
        XCTAssertNil(t.action(keyCode: UInt16(kVK_ANSI_X), flags: .command))
    }

    func testLaterLineOverridesSameTrigger() {
        let t = Keybinds.Table(lines: [
            "cmd+c=copy",
            "cmd+c=paste",
        ])
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_C), flags: .command),
            .paste
        )
    }

    func testEnterMatchesReturnAndKeypad() {
        let t = Keybinds.Table(lines: ["ctrl+enter=end_search"])
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_Return), flags: .control),
            .endSearch
        )
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_KeypadEnter), flags: .control),
            .endSearch
        )
    }

    func testCapsLockDoesNotChangeMatch() {
        let t = Keybinds.Table(lines: ["cmd+f=start_search"])
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_F), flags: [.command, .capsLock]),
            .startSearch
        )
    }

    func testConfigClearDropsPriorBinds() {
        let c = AppConfig.parse("""
            keybind = cmd+c=copy
            keybind = clear
            keybind = cmd+v=paste
            """)
        XCTAssertEqual(c.keybinds, ["cmd+v=paste"])
        let t = Keybinds.Table(lines: c.keybinds)
        XCTAssertNil(t.action(keyCode: UInt16(kVK_ANSI_C), flags: .command))
        XCTAssertEqual(
            t.action(keyCode: UInt16(kVK_ANSI_V), flags: .command),
            .paste
        )
    }
}

final class OpacityTests: XCTestCase {
    func testDefaultBgUsesOpacityExplicitStaysOpaque() {
        XCTAssertEqual(
            GridExpand.backgroundAlpha(
                cellBg: COLOR_DEFAULT, reverse: false, highlighted: false, defaultAlpha: 0.5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GridExpand.backgroundAlpha(
                cellBg: COLOR_INDEXED | 4, reverse: false, highlighted: false, defaultAlpha: 0.5
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GridExpand.backgroundAlpha(
                cellBg: COLOR_DEFAULT, reverse: true, highlighted: false, defaultAlpha: 0.5
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GridExpand.backgroundAlpha(
                cellBg: COLOR_DEFAULT, reverse: false, highlighted: true, defaultAlpha: 0.5
            ),
            1,
            accuracy: 0.001
        )
    }

    func testPackWritesBackgroundAlpha() {
        let c = CellInstance.pack(SIMD3<Float>(0, 0, 0), a: 0.5)
        XCTAssertEqual(c >> 24, 128)
    }
}
