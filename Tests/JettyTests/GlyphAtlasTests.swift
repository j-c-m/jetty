import CoreText
import XCTest
@testable import Jetty

final class GlyphAtlasTests: XCTestCase {
    func testBoldFaceIsExtraBold() {
        let regular = EmbeddedFonts.font(size: 20, bold: false, italic: false)
        let bold = EmbeddedFonts.font(size: 20, bold: true, italic: false)
        let italic = EmbeddedFonts.font(size: 20, bold: false, italic: true)
        let boldItalic = EmbeddedFonts.font(size: 20, bold: true, italic: true)
        let rName = CTFontCopyPostScriptName(regular) as String
        let bName = CTFontCopyPostScriptName(bold) as String
        let iName = CTFontCopyPostScriptName(italic) as String
        let biName = CTFontCopyPostScriptName(boldItalic) as String
        XCTAssertTrue(rName.contains("Regular") || rName.contains("JetBrains"), rName)
        XCTAssertTrue(bName.contains("ExtraBold"), bName)
        XCTAssertFalse(bName.contains("ExtraBoldItalic"), bName)
        XCTAssertTrue(iName.contains("Italic"), iName)
        XCTAssertFalse(iName.contains("Bold"), iName)
        XCTAssertTrue(biName.contains("ExtraBold") && biName.contains("Italic"), biName)
        XCTAssertNotEqual(rName, bName)
    }

    func testGrowsAndKeepsPackedInk() {
        let shelf = R8Shelf(edge: 8, maxEdge: 32)
        let a = [UInt8](repeating: 11, count: 8 * 4)
        let b = [UInt8](repeating: 22, count: 8 * 4)
        let ra = shelf.allocate(width: 8, height: 4)!
        shelf.blit(a, width: 8, height: 4, x: ra.x, y: ra.y)
        let rb = shelf.allocate(width: 8, height: 4)!
        shelf.blit(b, width: 8, height: 4, x: rb.x, y: rb.y)
        XCTAssertNil(shelf.allocate(width: 8, height: 4))

        let gen = shelf.generation
        let old = shelf.grow()
        XCTAssertEqual(old?.oldW, 8)
        XCTAssertEqual(shelf.width, 16)
        XCTAssertEqual(shelf.height, 16)
        XCTAssertEqual(shelf.generation, gen + 1)
        XCTAssertEqual(shelf.pixels[0], 11)
        XCTAssertEqual(shelf.pixels[4 * 16], 22)

        let rc = shelf.allocate(width: 8, height: 4)!
        XCTAssertEqual(rc.x, 0)
        XCTAssertEqual(rc.y, 8)

        let fw = Float(shelf.width)
        let fh = Float(shelf.height)
        XCTAssertEqual(Float(ra.x) / fw, 0)
        XCTAssertEqual(Float(ra.y + 4) / fh, 0.25, accuracy: 1e-6)
        XCTAssertEqual(Float(rb.y + 4) / fh, 0.5, accuracy: 1e-6)
    }

    func testGrowStopsAtMaxEdge() {
        let shelf = R8Shelf(edge: 8, maxEdge: 8)
        XCTAssertNil(shelf.grow())
        XCTAssertEqual(shelf.width, 8)
    }

    func testSpriteCoversBoxBlockBraille() {
        XCTAssertTrue(SpriteFace.covers(0x2502))
        XCTAssertTrue(SpriteFace.covers(0x2588))
        XCTAssertTrue(SpriteFace.covers(0x28FF))
        XCTAssertFalse(SpriteFace.covers(UInt32(UInt8(ascii: "A"))))
    }

    func testSpriteDrawsBrailleInk() {
        var cov: [UInt8] = []
        XCTAssertTrue(SpriteFace.draw(0x28FF, width: 12, height: 24, baseline: 4, into: &cov))
        XCTAssertEqual(cov.count, 12 * 24)
        XCTAssertTrue(cov.contains { $0 > 0 })
        var empty: [UInt8] = []
        XCTAssertTrue(SpriteFace.draw(0x2800, width: 12, height: 24, baseline: 4, into: &empty))
        XCTAssertFalse(empty.contains { $0 > 0 })
    }

    func testSpriteDrawsBoxWhenAsked() {
        var cov: [UInt8] = []
        XCTAssertTrue(SpriteFace.draw(0x2502, width: 12, height: 24, baseline: 4, into: &cov))
        XCTAssertTrue(cov.contains { $0 > 0 })
    }

    func testLockFillHasGrayCoverage() {
        let cov = GlyphAtlas.systemSymbolCoverage("lock.fill", width: 12, height: 24)
        XCTAssertNotNil(cov)
        XCTAssertEqual(cov?.count, 12 * 24)
        XCTAssertTrue(cov?.contains { $0 > 32 } == true)
        XCTAssertNil(GlyphAtlas.systemSymbolCoverage("", width: 12, height: 24))
        guard let device = MTLCreateSystemDefaultDevice(),
              let atlas = GlyphAtlas(
                device: device, metrics: CellMetrics.measure(fontSize: 20, backingScale: 2)
              )
        else { return }
        let g = atlas.systemSymbol("lock.fill")
        XCTAssertFalse(g.color)
        XCTAssertGreaterThan(g.uv.u1, g.uv.u0)
        XCTAssertGreaterThan(g.uv.v1, g.uv.v0)
        let again = atlas.systemSymbol("lock.fill")
        XCTAssertEqual(again.uv.u0, g.uv.u0)
        XCTAssertEqual(again.uv.v0, g.uv.v0)
        XCTAssertEqual(atlas.systemSymbol("").uv.u1, 0)
    }
}
