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
            macos-auto-secure-input = yes
            scrollback-lines = 100
            copy-on-select = no
            osc52-write = deny
            osc52-read = deny
            keybind = cmd+shift+up=jump_to_prompt:-1
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
        XCTAssertTrue(c.macosAutoSecureInput)
        XCTAssertEqual(c.scrollbackLines, 100)
        XCTAssertFalse(c.copyOnSelect)
        XCTAssertEqual(c.osc52Write, .deny)
        XCTAssertEqual(c.osc52Read, .deny)
        XCTAssertEqual(c.keybinds, ["cmd+shift+up=jump_to_prompt:-1"])
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
