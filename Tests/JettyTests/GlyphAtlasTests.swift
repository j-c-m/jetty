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
}
