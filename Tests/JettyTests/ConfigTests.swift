import CoreText
import CVt
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
            background = #1e1e2e
            foreground = cdd6f4
            cursor-color = #f5e0dc
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
        XCTAssertEqual(c.background, 0x1E1E2E)
        XCTAssertEqual(c.foreground, 0xCDD6F4)
        XCTAssertEqual(c.cursorColor, 0xF5E0DC)
        XCTAssertEqual(c.packedForeground, COLOR_RGB | 0xCDD6F4)
        XCTAssertEqual(c.packedBackground, COLOR_RGB | 0x1E1E2E)
        XCTAssertEqual(c.packedCursor, COLOR_RGB | 0xF5E0DC)
    }

    func testGhosttyThemeFileKeys() {
        let c = AppConfig.parse("""
            palette = 0=#11111b
            palette = 1=#f38ba8
            palette = 15 = #cdd6f4
            background = #1e1e2e
            foreground = #cdd6f4
            cursor-color = #f5e0dc
            cursor-text = #1e1e2e
            selection-background = #585b70
            selection-foreground = #cdd6f4
            """)
        XCTAssertEqual(c.background, 0x1E1E2E)
        XCTAssertEqual(c.foreground, 0xCDD6F4)
        XCTAssertEqual(c.cursorColor, 0xF5E0DC)
        XCTAssertEqual(c.paletteOverlay[0], 0x11111B)
        XCTAssertEqual(c.paletteOverlay[1], 0xF38BA8)
        XCTAssertEqual(c.paletteOverlay[15], 0xCDD6F4)
        XCTAssertEqual(
            c.paletteOverlayMask,
            UInt16(1 << 0) | UInt16(1 << 1) | UInt16(1 << 15)
        )
        XCTAssertEqual(AppConfig.parseColor("#abc"), 0xAABBCC)
        XCTAssertEqual(AppConfig.parseColor("red"), 0xFF0000)
        XCTAssertEqual(AppConfig.parseColor("\"#ff0000\""), 0xFF0000)
        XCTAssertNil(AppConfig.parse("foreground =").foreground)
        XCTAssertNil(AppConfig.parse("cursor-color = cell-foreground").cursorColor)
        XCTAssertEqual(AppConfig.parse("").packedForeground, COLOR_RGB | 0xCCCCCC)
        XCTAssertEqual(AppConfig.parse("").packedBackground, COLOR_RGB | 0x000000)
        XCTAssertEqual(AppConfig.parse("").packedCursor, COLOR_DEFAULT)
    }

    func testThemeLoadsThenConfigOverrides() {
        let files = [
            "mocha": """
                background = #1e1e2e
                foreground = #cdd6f4
                palette = 0=#11111b
                font-size = 12
                theme = ignored
                """,
            "day": "background = #ffffff\nforeground = #111111\n",
            "night": "background = #000000\nforeground = #eeeeee\n",
        ]
        let c = AppConfig.parse(
            """
            theme = mocha
            background = #ff0000
            """,
            loadTheme: { files[$0] }
        )
        XCTAssertEqual(c.background, 0xFF0000)
        XCTAssertEqual(c.foreground, 0xCDD6F4)
        XCTAssertEqual(c.paletteOverlay[0], 0x11111B)
        XCTAssertEqual(c.fontSize, 12)

        let dark = AppConfig.parse(
            "theme = light:day,dark:night",
            dark: true,
            loadTheme: { files[$0] }
        )
        XCTAssertEqual(dark.background, 0x000000)
        XCTAssertEqual(dark.foreground, 0xEEEEEE)
        let light = AppConfig.parse(
            "theme = dark:night, light:day",
            dark: false,
            loadTheme: { files[$0] }
        )
        XCTAssertEqual(light.background, 0xFFFFFF)
        XCTAssertEqual(
            AppConfig.resolveThemeName("light:Rose Pine Dawn,dark:Rose Pine", dark: false),
            "Rose Pine Dawn"
        )
        XCTAssertEqual(
            AppConfig.parse("theme = missing", loadTheme: { _ in nil }).background,
            nil
        )
    }

    func testGhosttyWindowAndOptionKeys() {
        let pad = AppConfig.parse("""
            window-padding-x = 2
            window-padding-y = 1,3
            window-width = 80
            window-height = 24
            macos-option-as-alt = left
            """)
        XCTAssertEqual(pad.windowPaddingLeft, 2)
        XCTAssertEqual(pad.windowPaddingRight, 2)
        XCTAssertEqual(pad.windowPaddingTop, 1)
        XCTAssertEqual(pad.windowPaddingBottom, 3)
        XCTAssertEqual(pad.launchCols, 80)
        XCTAssertEqual(pad.launchRows, 24)
        XCTAssertEqual(pad.macosOptionAsAlt, .left)
        XCTAssertEqual(AppConfig.parsePadPair("2, 8")?.0, 2)
        XCTAssertEqual(AppConfig.parsePadPair("2, 8")?.1, 8)
        XCTAssertEqual(AppConfig.parse("window-width = 80").launchCols, 105)
        XCTAssertEqual(AppConfig.parse("window-height = 24").launchRows, 35)
        XCTAssertEqual(
            AppConfig.parse("window-width = 5\nwindow-height = 2").launchCols,
            10
        )
        XCTAssertEqual(
            AppConfig.parse("window-width = 5\nwindow-height = 2").launchRows,
            4
        )
        XCTAssertEqual(AppConfig.parse("macos-option-as-alt = true").macosOptionAsAlt, .on)
        XCTAssertEqual(AppConfig.parse("macos-option-as-alt = false").macosOptionAsAlt, .off)
        XCTAssertEqual(AppConfig.parse("macos-option-as-alt = right").macosOptionAsAlt, .right)
        XCTAssertEqual(AppConfig.parse("macos-option-as-alt =").macosOptionAsAlt, .unset)
        XCTAssertEqual(AppConfig.parse("window-padding-x =").windowPaddingLeft, 4)
        let on = AppConfig.parse("macos-option-as-alt = true")
        XCTAssertTrue(on.optionAsAltActive(optionDown: true, leftOption: true, rightOption: false, usLayout: false))
        let unsetUS = AppConfig.parse("")
        XCTAssertTrue(unsetUS.optionAsAltActive(optionDown: true, leftOption: true, rightOption: false, usLayout: true))
        XCTAssertFalse(unsetUS.optionAsAltActive(optionDown: true, leftOption: true, rightOption: false, usLayout: false))
        let left = AppConfig.parse("macos-option-as-alt = left")
        XCTAssertTrue(left.optionAsAltActive(optionDown: true, leftOption: true, rightOption: false, usLayout: false))
        XCTAssertFalse(left.optionAsAltActive(optionDown: true, leftOption: false, rightOption: true, usLayout: false))
    }

    func testGhosttyCursorStyle() {
        XCTAssertEqual(AppConfig.parse("cursor-style = bar").cursorStyle, .bar)
        XCTAssertEqual(AppConfig.parse("cursor-style = bar").packedCursorStyle, 6)
        XCTAssertEqual(AppConfig.parse("cursor-style = underline").packedCursorStyle, 4)
        XCTAssertEqual(AppConfig.parse("cursor-style = block_hollow").cursorStyle, .blockHollow)
        XCTAssertTrue(AppConfig.parse("cursor-style = block_hollow").cursorHollow)
        XCTAssertEqual(AppConfig.parse("cursor-style = block_hollow").packedCursorStyle, 2)
        let blink = AppConfig.parse("""
            cursor-style = bar
            cursor-style-blink = true
            """)
        XCTAssertEqual(blink.packedCursorStyle, 5)
        XCTAssertTrue(blink.cursorStyleBlink)
        XCTAssertEqual(AppConfig.parse("cursor-style-blink = false").packedCursorStyle, 2)
        XCTAssertEqual(AppConfig.parse("cursor-style = bar\ncursor-style =").cursorStyle, .block)
        XCTAssertFalse(AppConfig.parse("cursor-style-blink = true\ncursor-style-blink =").cursorStyleBlink)
        XCTAssertEqual(AppConfig.parseCursorStyle("BLOCK"), .block)
        XCTAssertNil(AppConfig.parseCursorStyle("caret"))
    }

    func testGhosttyCommandEnvPasteClose() {
        let c = AppConfig.parse("""
            command = fish
            working-directory = home
            env = FOO=bar
            env = BAZ=qux
            env = FOO=
            clipboard-paste-protection = false
            confirm-close-surface = always
            """)
        XCTAssertEqual(c.command, "fish")
        XCTAssertEqual(c.workingDirectory, .home)
        XCTAssertNil(c.env["FOO"])
        XCTAssertEqual(c.env["BAZ"], "qux")
        XCTAssertEqual(c.envAssignments, ["BAZ=qux"])
        XCTAssertFalse(c.clipboardPasteProtection)
        XCTAssertEqual(c.confirmCloseSurface, .always)
        XCTAssertEqual(AppConfig.parse("working-directory = inherit").workingDirectory, .inherit)
        XCTAssertEqual(AppConfig.parse("working-directory = ~/src").workingDirectory, .path("~/src"))
        XCTAssertEqual(AppConfig.parse("command = direct:nvim foo").command, "direct:nvim foo")
        XCTAssertEqual(AppConfig.parse("confirm-close-surface = false").confirmCloseSurface, .off)
        XCTAssertEqual(AppConfig.parse("env = A=1\nenv =").env.count, 0)
        XCTAssertNil(AppConfig.parse("command =").command)
        XCTAssertEqual(AppConfig.parse("").workingDirectory, .unset)
        XCTAssertTrue(AppConfig.parse("").clipboardPasteProtection)
        XCTAssertEqual(AppConfig.parse("").confirmCloseSurface, .on)
        XCTAssertEqual(AppConfig.parse("").command, nil)
    }

    func testThemeAbsolutePath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetty-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Catppuccin Mocha")
        try "background = #1e1e2e\npalette = 0=#010203\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let c = AppConfig.parse("theme = \(url.path)")
        XCTAssertEqual(c.background, 0x1E1E2E)
        XCTAssertEqual(c.paletteOverlay[0], 0x010203)
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
        XCTAssertNil(c.foreground)
        XCTAssertNil(c.background)
        XCTAssertNil(c.cursorColor)
        XCTAssertEqual(c.windowPaddingLeft, 4)
        XCTAssertEqual(c.windowPaddingRight, 4)
        XCTAssertEqual(c.windowPaddingTop, 4)
        XCTAssertEqual(c.windowPaddingBottom, 4)
        XCTAssertNil(c.windowWidth)
        XCTAssertNil(c.windowHeight)
        XCTAssertEqual(c.launchCols, 105)
        XCTAssertEqual(c.launchRows, 35)
        XCTAssertEqual(c.macosOptionAsAlt, .unset)
        XCTAssertEqual(c.cursorStyle, .block)
        XCTAssertFalse(c.cursorStyleBlink)
        XCTAssertEqual(c.packedCursorStyle, 2)
        XCTAssertFalse(c.cursorHollow)
        XCTAssertNil(c.command)
        XCTAssertEqual(c.workingDirectory, .unset)
        XCTAssertTrue(c.env.isEmpty)
        XCTAssertTrue(c.clipboardPasteProtection)
        XCTAssertEqual(c.confirmCloseSurface, .on)
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
