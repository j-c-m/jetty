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
}
