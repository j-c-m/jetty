import CoreText
import XCTest
@testable import Jetty

final class ConfigTests: XCTestCase {
    func testParsesDesignKeys() {
        let c = AppConfig.parse("""
            # comment
            font-family = Menlo
            font-size = 18
            ligatures = programming
            font-feature = -calt
            adjust-cell-width = -1
            adjust-cell-height = 2
            background-opacity = 0.5
            palette-0 = #010203
            palette-15 = f2f0ec
            link-url = false
            desktop-notifications = 0
            progress-style = false
            macos-auto-secure-input = yes
            macos-applescript = 0
            scrollback-lines = 100
            copy-on-select = no
            osc52-write = deny
            osc52-read = deny
            keybind = cmd+shift+up=jump_to_prompt:-1
            shell-integration = none
            notify-on-command-finish = unfocused
            notify-on-command-finish-after = 10s
            notify-on-command-finish-action = no-bell,notify
            unknown-key = ignored
            """)
        XCTAssertEqual(c.fontFamily, "Menlo")
        XCTAssertEqual(c.fontSize, 18)
        XCTAssertEqual(c.ligatures, .programming)
        XCTAssertEqual(c.fontFeature, "-calt")
        XCTAssertEqual(c.adjustCellWidth, -1)
        XCTAssertEqual(c.adjustCellHeight, 2)
        XCTAssertEqual(c.backgroundOpacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.paletteOverlayMask, UInt16(1 << 0) | UInt16(1 << 15))
        XCTAssertEqual(c.paletteOverlay[0], 0x010203)
        XCTAssertEqual(c.paletteOverlay[15], 0xF2F0EC)
        XCTAssertFalse(c.linkURL)
        XCTAssertFalse(c.desktopNotifications)
        XCTAssertFalse(c.progressStyle)
        XCTAssertTrue(c.macosAutoSecureInput)
        XCTAssertFalse(c.macosAppleScript)
        XCTAssertEqual(c.scrollbackLines, 100)
        XCTAssertFalse(c.copyOnSelect)
        XCTAssertEqual(c.osc52Write, .deny)
        XCTAssertEqual(c.osc52Read, .deny)
        XCTAssertEqual(c.keybinds, ["cmd+shift+up=jump_to_prompt:-1"])
        XCTAssertEqual(c.shellIntegration, .none)
        XCTAssertEqual(c.notifyOnCommandFinish, .unfocused)
        XCTAssertEqual(c.notifyOnCommandFinishAfter, 10)
        XCTAssertEqual(AppConfig.parseSeconds("10s"), 10)
        XCTAssertEqual(AppConfig.parseSeconds("10"), 10)
        XCTAssertEqual(AppConfig.parseSeconds("1m30s"), 90)
        XCTAssertEqual(AppConfig.parseSeconds("1h30m"), 5_400)
        XCTAssertEqual(AppConfig.parseSeconds("500ms") ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(AppConfig.parse("notify-on-command-finish-after = 1m30s").notifyOnCommandFinishAfter, 90)
        XCTAssertNil(AppConfig.parseSeconds("1x"))
        XCTAssertNil(AppConfig.parseSeconds("1m30"))
        XCTAssertFalse(c.notifyOnCommandFinishBell)
        XCTAssertTrue(c.notifyOnCommandFinishDesktop)
        XCTAssertTrue(AppConfig.parse("").kittyGraphics)
        XCTAssertFalse(AppConfig.parse("kitty-graphics = off").kittyGraphics)
        XCTAssertFalse(AppConfig.parse("kitty-graphics = no").kittyGraphics)
        XCTAssertTrue(AppConfig.parse("kitty-graphics = on").kittyGraphics)
    }

    func testOpenConfigShellCommandUsesEditor() {
        XCTAssertEqual(
            AppConfig.openConfigShellCommand(
                path: "/tmp/jetty/config", env: ["EDITOR": "nvim"]
            ),
            "exec nvim '/tmp/jetty/config'"
        )
        XCTAssertEqual(
            AppConfig.openConfigShellCommand(
                path: "/tmp/a'b", env: ["EDITOR": "emacs -nw"]
            ),
            "exec emacs -nw '/tmp/a'\\''b'"
        )
        XCTAssertNil(AppConfig.openConfigShellCommand(path: "/x", env: [:]))
        XCTAssertNil(AppConfig.openConfigShellCommand(path: "/x", env: ["EDITOR": "  "]))
        XCTAssertEqual(AppConfig.editorCommand(env: ["EDITOR": " vim "]), "vim")
        XCTAssertEqual(AppConfig.editorCommand(env: ["VISUAL": "emacs", "EDITOR": "vim"]), "emacs")
        XCTAssertEqual(
            AppConfig.openConfigShellCommand(
                path: "/x", env: ["EDITOR": "vim"], editor: "nvim"
            ),
            "exec nvim '/x'"
        )
        XCTAssertEqual(
            AppConfig.openConfigShellCommand(
                path: "/x", env: ["EDITOR": "vim"], editor: "  "
            ),
            "exec vim '/x'"
        )
        let parsed = ShellEnv.parseEnv0(Data("VISUAL=emacs\0EDITOR=nvim\0PATH=/bin\0".utf8))
        XCTAssertEqual(parsed["VISUAL"], "emacs")
        XCTAssertEqual(parsed["EDITOR"], "nvim")
        XCTAssertEqual(ShellEnv.editor(from: parsed), "emacs")
        XCTAssertEqual(ShellEnv.editor(from: ["EDITOR": "vim"]), "vim")
        XCTAssertNil(ShellEnv.editor(from: [:]))
    }

    func testEnsureConfigFileCreates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetty-cfg-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("jetty/config")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let got = AppConfig.ensureConfigFile(at: url)
        XCTAssertEqual(got, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        AppConfig.ensureConfigFile(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testEmptyFamilyIsOmitted() {
        let c = AppConfig.parse("font-family =\nligatures = false")
        XCTAssertNil(c.fontFamily)
        XCTAssertEqual(c.ligatures, .off)
    }

    func testDefaultsMatchBundledMono() {
        let c = AppConfig.parse("")
        XCTAssertNil(c.fontFamily)
        XCTAssertEqual(c.fontSize, 20)
        XCTAssertEqual(c.ligatures, .programming)
        XCTAssertEqual(c.adjustCellWidth, 0)
        XCTAssertEqual(c.paletteOverlayMask, 0)
        XCTAssertEqual(c.backgroundOpacity, 1)
        XCTAssertTrue(c.linkURL)
        XCTAssertTrue(c.desktopNotifications)
        XCTAssertTrue(c.progressStyle)
        XCTAssertTrue(c.macosAppleScript)
        XCTAssertEqual(c.shellIntegration, .detect)
        XCTAssertEqual(c.notifyOnCommandFinish, .never)
        XCTAssertEqual(c.notifyOnCommandFinishAfter, 5)
        XCTAssertTrue(c.notifyOnCommandFinishBell)
        XCTAssertFalse(c.notifyOnCommandFinishDesktop)
    }

    func testLigaturesAliases() {
        XCTAssertEqual(AppConfig.parse("ligatures = off").ligatures, .off)
        XCTAssertEqual(AppConfig.parse("ligatures = false").ligatures, .off)
        XCTAssertEqual(AppConfig.parse("ligatures = programming").ligatures, .programming)
        XCTAssertEqual(AppConfig.parse("ligatures = on").ligatures, .on)
        XCTAssertEqual(AppConfig.parse("ligatures = true").ligatures, .on)
        XCTAssertEqual(AppConfig.parse("ligatures = nope").ligatures, .programming)
    }

    func testAdjustCellClampsToOne() {
        let base = CellMetrics.measure(fontSize: 20, backingScale: 2)
        let tiny = CellMetrics.measure(
            fontSize: 20, backingScale: 2, adjustWidth: -10_000, adjustHeight: -10_000
        )
        XCTAssertEqual(tiny.cellWidthPx, 1)
        XCTAssertEqual(tiny.cellHeightPx, 1)
        let wide = CellMetrics.measure(
            fontSize: 20, backingScale: 2, adjustWidth: 3, adjustHeight: 4
        )
        XCTAssertEqual(wide.cellWidthPx, base.cellWidthPx + 3)
        XCTAssertEqual(wide.cellHeightPx, base.cellHeightPx + 4)
    }

    func testMissingFamilyFallsBackToBundled() {
        let bundled = EmbeddedFonts.font(size: 20, bold: false, italic: false)
        let faces = EmbeddedFonts.fonts(family: "JettyMissingFamilyXYZ", size: 20)
        let want = CTFontCopyPostScriptName(bundled) as String
        let got = CTFontCopyPostScriptName(faces.regular) as String
        XCTAssertEqual(got, want)
    }

    func testSystemFamilyMenlo() {
        let faces = EmbeddedFonts.fonts(family: "Menlo", size: 20)
        XCTAssertEqual(CTFontCopyFamilyName(faces.regular) as String, "Menlo")
        let boldName = CTFontCopyPostScriptName(faces.bold) as String
        XCTAssertNotEqual(boldName, CTFontCopyPostScriptName(faces.regular) as String)
    }

    func testBundledFamilyNameUsesEmbedded() {
        let faces = EmbeddedFonts.fonts(family: EmbeddedFonts.familyName, size: 20)
        let bundled = EmbeddedFonts.font(size: 20, bold: true, italic: false)
        XCTAssertEqual(
            CTFontCopyPostScriptName(faces.bold) as String,
            CTFontCopyPostScriptName(bundled) as String
        )
    }
}
