import CoreGraphics
import CoreText
import Foundation
import Metal

/// Square R8 shelf packer. Doubles on full (ghosvt / Ghostty `Atlas.grow`).
final class R8Shelf {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: [UInt8]
    private(set) var generation = 0
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    let maxEdge: Int

    init(edge: Int, maxEdge: Int = 16384) {
        let e = max(1, min(edge, maxEdge))
        self.width = e
        self.height = e
        self.pixels = [UInt8](repeating: 0, count: e * e)
        self.maxEdge = maxEdge
    }

    func allocate(width w: Int, height h: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        if shelfX + w > width {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        if shelfY + h > height { return nil }
        let x = shelfX
        let y = shelfY
        shelfX += w
        shelfH = max(shelfH, h)
        return (x, y, w, h)
    }

    /// Copies ink into a doubled square. New glyphs pack in the bottom band.
    @discardableResult
    func grow() -> (oldW: Int, oldH: Int)? {
        let oldW = width
        let oldH = height
        let newW = min(oldW * 2, maxEdge)
        let newH = min(oldH * 2, maxEdge)
        if newW <= oldW && newH <= oldH { return nil }
        var next = [UInt8](repeating: 0, count: newW * newH)
        pixels.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            next.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                for y in 0..<oldH {
                    d.advanced(by: y * newW).update(from: s.advanced(by: y * oldW), count: oldW)
                }
            }
        }
        pixels = next
        width = newW
        height = newH
        shelfX = 0
        shelfY = oldH
        shelfH = 0
        generation &+= 1
        return (oldW, oldH)
    }

    func clear() {
        pixels = [UInt8](repeating: 0, count: width * height)
        shelfX = 0
        shelfY = 0
        shelfH = 0
        generation &+= 1
    }

    func blit(_ coverage: [UInt8], width w: Int, height h: Int, x: Int, y: Int) {
        coverage.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            pixels.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                for row in 0..<h {
                    d.advanced(by: (y + row) * width + x)
                        .update(from: s.advanced(by: row * w), count: w)
                }
            }
        }
    }
}

public final class GlyphAtlas {
    public struct UV: Sendable {
        public var u0, v0, u1, v1: Float
        public static let empty = UV(u0: 0, v0: 0, u1: 0, v1: 0)
    }

    public private(set) var texture: MTLTexture
    public let cellW: Int
    public let cellH: Int
    public let metrics: CellMetrics
    /// Bumped on `clear()` / `grow()`. Instance UVs from an in-flight expand are stale until retry.
    var packGeneration: Int { shelf.generation }

    private var shelf: R8Shelf
    private var cache: [UInt64: UV] = [:]
    private let device: MTLDevice

    static let maxAtlasEdge = 16384

    public init?(device: MTLDevice, metrics: CellMetrics, edge: Int = 1024) {
        self.device = device
        self.metrics = metrics
        self.cellW = metrics.cellWidthPx
        self.cellH = metrics.cellHeightPx
        let shelf = R8Shelf(edge: edge, maxEdge: Self.maxAtlasEdge)
        self.shelf = shelf
        guard let tex = Self.makeTexture(device: device, width: shelf.width, height: shelf.height) else {
            return nil
        }
        self.texture = tex
    }

    public func uv(scalar: UInt32, bold: Bool, italic: Bool) -> UV {
        if scalar == 0 || scalar == 0x20 { return .empty }
        let key = UInt64(scalar)
            | (bold ? 1 << 32 : 0)
            | (italic ? 1 << 33 : 0)
        if let hit = cache[key] { return hit }
        let uv = rasterize(scalar: scalar, bold: bold, italic: italic)
        cache[key] = uv
        return uv
    }

    private func rasterize(scalar: UInt32, bold: Bool, italic: Bool) -> UV {
        guard let us = UnicodeScalar(scalar) else { return .empty }
        let font = metrics.face(bold: bold, italic: italic)
        let str = String(Character(us)) as CFString
        var used = font
        let fallback = CTFontCreateForString(font, str, CFRange(location: 0, length: CFStringGetLength(str)))
        let name = CTFontCopyPostScriptName(fallback) as String
        if !name.contains("LastResort") {
            used = fallback
        }

        let w = cellW
        let h = cellH
        let bpr = (w * 4 + 15) & ~15
        var rgba = [UInt8](repeating: 0, count: bpr * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .empty }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.textMatrix = .identity
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: used,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(Character(us)), attributes: attrs)
        )
        ctx.textPosition = CGPoint(x: 0, y: CGFloat(metrics.cellBaselinePx))
        CTLineDraw(line, ctx)

        var coverage = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = row * bpr
            let dst = row * w
            for col in 0..<w {
                let o = src + col * 4
                coverage[dst + col] = max(rgba[o + 3], rgba[o])
            }
        }

        if let rect = shelf.allocate(width: w, height: h) {
            return write(coverage, width: w, height: h, rect: rect)
        }
        // ghosvt / Ghostty SharedGrid: AtlasFull → grow(size * 2), keep packed glyphs.
        if grow(), let rect = shelf.allocate(width: w, height: h) {
            return write(coverage, width: w, height: h, rect: rect)
        }
        clear()
        guard let rect = shelf.allocate(width: w, height: h) else { return .empty }
        return write(coverage, width: w, height: h, rect: rect)
    }

    private func write(
        _ coverage: [UInt8],
        width w: Int,
        height h: Int,
        rect: (x: Int, y: Int, w: Int, h: Int)
    ) -> UV {
        shelf.blit(coverage, width: w, height: h, x: rect.x, y: rect.y)
        upload(region: MTLRegionMake2D(rect.x, rect.y, rect.w, rect.h))
        let fw = Float(shelf.width)
        let fh = Float(shelf.height)
        return UV(
            u0: Float(rect.x) / fw,
            v0: Float(rect.y) / fh,
            u1: Float(rect.x + w) / fw,
            v1: Float(rect.y + h) / fh
        )
    }

    @discardableResult
    private func grow() -> Bool {
        let oldW = shelf.width
        let oldH = shelf.height
        let newW = min(oldW * 2, Self.maxAtlasEdge)
        let newH = min(oldH * 2, Self.maxAtlasEdge)
        if newW <= oldW && newH <= oldH { return false }
        guard let tex = Self.makeTexture(device: device, width: newW, height: newH) else {
            return false
        }
        guard shelf.grow() != nil else { return false }
        let sx = Float(oldW) / Float(shelf.width)
        let sy = Float(oldH) / Float(shelf.height)
        for (key, uv) in cache {
            cache[key] = UV(u0: uv.u0 * sx, v0: uv.v0 * sy, u1: uv.u1 * sx, v1: uv.v1 * sy)
        }
        texture = tex
        uploadFull()
        return true
    }

    private func clear() {
        cache.removeAll(keepingCapacity: true)
        shelf.clear()
        uploadFull()
    }

    private func uploadFull() {
        texture.replace(
            region: MTLRegionMake2D(0, 0, shelf.width, shelf.height),
            mipmapLevel: 0,
            withBytes: shelf.pixels,
            bytesPerRow: shelf.width
        )
    }

    private func upload(region: MTLRegion) {
        let x = Int(region.origin.x)
        let y = Int(region.origin.y)
        let stride = shelf.width
        shelf.pixels.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: y * stride + x)
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: ptr,
                bytesPerRow: stride
            )
        }
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }
}
