import CVt
import Metal
import simd
import XCTest
@testable import Jetty

final class CellInstanceTests: XCTestCase {
    func testPackedStrideAndOffsets() {
        XCTAssertEqual(MemoryLayout<CellInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<CellInstance>.size, 32)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.ox), 0 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.sx), 4 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.u0), 8 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.fg), 16 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.bg), 20 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.atlas), 24 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \CellInstance.flags), 25 as Int?)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 32)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.size, 32)
        XCTAssertEqual(MemoryLayout.offset(of: \FrameUniforms.atlasW), 16 as Int?)
        XCTAssertEqual(MemoryLayout.offset(of: \FrameUniforms.colorAtlasW), 24 as Int?)
    }

    func testPackRGBA8() {
        let c = CellInstance.pack(SIMD3<Float>(1, 0.5, 0), a: 1)
        XCTAssertEqual(c & 0xFF, 255)
        XCTAssertEqual((c >> 8) & 0xFF, 128)
        XCTAssertEqual((c >> 16) & 0xFF, 0)
        XCTAssertEqual(c >> 24, 255)
    }

    func testEmptyHasNoGlyph() {
        XCTAssertEqual(CellInstance.empty.flags, 0)
        XCTAssertEqual(CellInstance.empty.sx, 0)
        let inst = CellInstance(
            originX: 10, originY: 20,
            width: 12, height: 24,
            uv: GlyphAtlas.UV(u0: 1, v0: 2, u1: 13, v1: 26),
            fgRGB: SIMD3<Float>(1, 1, 1),
            bgRGB: SIMD3<Float>(0, 0, 0),
            colorAtlas: false
        )
        XCTAssertEqual(inst.ox, 10)
        XCTAssertEqual(inst.oy, 20)
        XCTAssertEqual(inst.sx, 12)
        XCTAssertEqual(inst.u0, 1)
        XCTAssertEqual(inst.u1, 13)
        XCTAssertEqual(inst.flags, CellInstance.hasGlyphFlag)
        XCTAssertEqual(inst.atlas, 0)
    }

    func testMetalAcceptsPackedInstance() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let metrics = CellMetrics.measure(fontSize: 20, backingScale: 2)
        guard let atlas = GlyphAtlas(device: device, metrics: metrics) else {
            XCTFail("atlas")
            return
        }
        XCTAssertNotNil(TerminalRenderer(device: device, atlas: atlas))
    }

    func testBgOnlyDefaultHasZeroSizeGlyphsKeepCoverage() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let metrics = CellMetrics.measure(fontSize: 20, backingScale: 2)
        guard let atlas = GlyphAtlas(device: device, metrics: metrics) else {
            XCTFail("atlas")
            return
        }
        let pal = [SIMD3<Float>](repeating: SIMD3(0, 0, 0), count: 256)
        let cells = [
            Cell(content: content_scalar(0x41, WIDE_NARROW), fg: COLOR_DEFAULT, bg: COLOR_DEFAULT, attrs: 0, extra: 0),
            Cell(content: content_scalar(0x42, WIDE_NARROW), fg: COLOR_DEFAULT, bg: COLOR_INDEXED | 4, attrs: 0, extra: 0),
        ]
        var bg = [CellInstance.empty, CellInstance.empty]
        var glyphs = [CellInstance.empty, CellInstance.empty]
        let hide: [UInt8] = [0, 1]
        pal.withUnsafeBufferPointer { palBuf in
            cells.withUnsafeBufferPointer { cellBuf in
                bg.withUnsafeMutableBufferPointer { dest in
                    GridExpand.expandRow(
                        rowCells: cellBuf.baseAddress!,
                        cols: 2,
                        rowY: 0,
                        cellW: 12,
                        cellH: 24,
                        originX: 0,
                        originY: 0,
                        palette: palBuf.baseAddress!,
                        defFG: SIMD3(1, 1, 1),
                        defBG: SIMD3(0, 0, 0),
                        atlas: atlas,
                        cursorX: -1,
                        cursorY: -1,
                        cursorVisible: false,
                        selection: nil,
                        pass: .bgOnly,
                        dest: dest.baseAddress!
                    )
                }
                hide.withUnsafeBufferPointer { hideBuf in
                    glyphs.withUnsafeMutableBufferPointer { dest in
                        GridExpand.expandRow(
                            rowCells: cellBuf.baseAddress!,
                            cols: 2,
                            rowY: 0,
                            cellW: 12,
                            cellH: 24,
                            originX: 0,
                            originY: 0,
                            palette: palBuf.baseAddress!,
                            defFG: SIMD3(1, 1, 1),
                            defBG: SIMD3(0, 0, 0),
                            atlas: atlas,
                            cursorX: -1,
                            cursorY: -1,
                            cursorVisible: false,
                            selection: nil,
                            hideGlyphs: hideBuf.baseAddress,
                            pass: .glyphsOnly,
                            dest: dest.baseAddress!
                        )
                    }
                }
            }
        }
        XCTAssertEqual(bg[0].sx, 0)
        XCTAssertEqual(bg[1].sx, 12)
        XCTAssertEqual(bg[0].flags, 0)
        XCTAssertEqual(glyphs[0].flags, CellInstance.hasGlyphFlag)
        XCTAssertEqual(glyphs[1].flags, 0)
        XCTAssertEqual(glyphs[1].sx, 12)
        XCTAssertEqual(glyphs[0].bg >> 24, 0)
    }
}
