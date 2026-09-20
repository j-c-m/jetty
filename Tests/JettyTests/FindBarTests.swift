import AppKit
import CoreText
import XCTest
@testable import Jetty

@MainActor
final class FindFieldTests: XCTestCase {
    func testFieldIsEditable() {
        let field = FindField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.isSelectable)
    }
}

final class FindBarChromeTests: XCTestCase {
    func testPaintIdentity() {
        let rgb = RGB(r: 0xCC, g: 0x80, b: 0x10)
        XCTAssertEqual(FindBarChrome.paint(rgb, reverse: false), rgb)
    }

    func testPaintReverseInvertsChannels() {
        let rgb = RGB(r: 0xCC, g: 0x80, b: 0x10)
        XCTAssertEqual(
            FindBarChrome.paint(rgb, reverse: true),
            RGB(r: 0x33, g: 0x7F, b: 0xEF)
        )
    }

    func testDimMatchesAttrDim() {
        let rgb = RGB(r: 255, g: 204, b: 51)
        let c = FindBarChrome.dim(rgb)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1 * FindBarChrome.dimScale, accuracy: 0.0001)
        XCTAssertEqual(g, 204.0 / 255 * FindBarChrome.dimScale, accuracy: 0.0001)
        XCTAssertEqual(b, 51.0 / 255 * FindBarChrome.dimScale, accuracy: 0.0001)
        XCTAssertEqual(a, 1, accuracy: 0.0001)
    }

    func testStrokeAlpha() {
        let c = FindBarChrome.srgb(RGB(r: 255, g: 0, b: 0), alpha: FindBarChrome.strokeAlpha)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.0001)
        XCTAssertEqual(a, 0.4, accuracy: 0.0001)
        XCTAssertEqual(FindBarChrome.strokeAlpha, 0.4, accuracy: 0.0001)
    }

    func testCenteredTitleRect() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 24)
        XCTAssertEqual(
            FindBarChrome.centeredTitleRect(bounds: bounds, textHeight: 14),
            CGRect(x: 0, y: 5, width: 100, height: 14)
        )
        XCTAssertEqual(
            FindBarChrome.centeredTitleRect(bounds: bounds, textHeight: 24),
            bounds
        )
    }

    func testLineHeightAndBaselineMatchTextView() {
        let font = NSFont.systemFont(ofSize: 20)
        let lm = NSLayoutManager()
        XCTAssertEqual(FindBarChrome.lineHeight(font: font), lm.defaultLineHeight(for: font))
        let rect = CGRect(x: 0, y: 0, width: 100, height: lm.defaultLineHeight(for: font))
        let fromBottom = lm.defaultBaselineOffset(for: font)
        XCTAssertEqual(
            FindBarChrome.baselineY(in: rect, font: font, flipped: true),
            rect.maxY - fromBottom
        )
        XCTAssertEqual(
            FindBarChrome.baselineY(in: rect, font: font, flipped: false),
            rect.minY + fromBottom
        )
    }

    func testUiFontUsesPointSizeNotPixels() {
        let m = CellMetrics.measure(fontSize: 20, backingScale: 2)
        XCTAssertEqual(m.fontPx, 40, accuracy: 0.01)
        XCTAssertEqual(CTFontGetSize(m.font), 40, accuracy: 0.01)
        let font = FindBarChrome.uiFont(
            face: m.font, fontPx: m.fontPx, cellWidthPx: m.cellWidthPx, backingScale: 2
        )
        XCTAssertEqual(font.pointSize, m.fontSize, accuracy: 1)
        XCTAssertEqual(font.familyName, CTFontCopyFamilyName(m.font) as String)
    }

    func testUiFontAdvanceMatchesCell() {
        let m = CellMetrics.measure(fontSize: 20, backingScale: 2)
        let font = FindBarChrome.uiFont(
            face: m.font, fontPx: m.fontPx, cellWidthPx: m.cellWidthPx, backingScale: 2
        )
        let cellW = CGFloat(m.cellWidthPx) / 2
        XCTAssertEqual(font.maximumAdvancement.width, cellW, accuracy: 0.05)
    }
}

final class FindBarLayoutTests: XCTestCase {
    func testSizeInCells() {
        let size = FindBarLayout.size(cellW: 12, cellH: 24)
        XCTAssertEqual(size.width, 4 * FindBarLayout.innerPad + 33 * 12)
        XCTAssertEqual(size.height, 2 * FindBarLayout.innerPad + 24)
        XCTAssertEqual(FindBarLayout.fieldFrame(cellW: 12, cellH: 24).height, 24)
        XCTAssertEqual(FindBarLayout.fieldFrame(cellW: 12, cellH: 24).width, 240)
        XCTAssertEqual(FindBarLayout.countFrame(cellW: 12, cellH: 24).width, 132)
        XCTAssertEqual(FindBarLayout.upFrame(cellW: 12, cellH: 24).width, 12)
        XCTAssertEqual(FindBarLayout.downFrame(cellW: 12, cellH: 24).minX, FindBarLayout.upFrame(cellW: 12, cellH: 24).maxX)
    }

    func testTopRightInContent() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = FindBarLayout.size(cellW: 12, cellH: 24)
        XCTAssertEqual(
            FindBarLayout.frame(
                bounds: bounds, flipped: false, safeTop: 0, safeRight: 0, safeLeft: 0, size: size
            ),
            CGRect(x: 800 - size.width - 8, y: 600 - size.height - 8, width: size.width, height: size.height)
        )
        XCTAssertEqual(
            FindBarLayout.frame(
                bounds: bounds, flipped: true, safeTop: 0, safeRight: 0, safeLeft: 0, size: size
            ),
            CGRect(x: 800 - size.width - 8, y: 8, width: size.width, height: size.height)
        )
    }

    func testVisibleWhenTitlebarHidden() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = FindBarLayout.size(cellW: 12, cellH: 24)
        let frame = FindBarLayout.frame(
            bounds: bounds, flipped: false, safeTop: 0, safeRight: 0, safeLeft: 0, size: size
        )
        XCTAssertTrue(bounds.contains(frame))
        XCTAssertGreaterThan(frame.minY, 0)
        XCTAssertLessThan(frame.maxY, bounds.height)
    }

    func testBelowSafeTop() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = FindBarLayout.size(cellW: 12, cellH: 24)
        let frame = FindBarLayout.frame(
            bounds: bounds, flipped: false, safeTop: 28, safeRight: 0, safeLeft: 0, size: size
        )
        XCTAssertEqual(frame.maxY, bounds.height - 28 - FindBarLayout.margin)
        XCTAssertTrue(bounds.contains(frame))
    }
}
