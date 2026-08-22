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

/// Ghostty `atlas_color` default 512² BGRA, doubles on full.
final class BGRAShelf {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: [UInt8]
    private(set) var generation = 0
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    let maxEdge: Int
    static let bpp = 4

    init(edge: Int, maxEdge: Int = 16384) {
        let e = max(1, min(edge, maxEdge))
        self.width = e
        self.height = e
        self.pixels = [UInt8](repeating: 0, count: e * e * Self.bpp)
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

    @discardableResult
    func grow() -> (oldW: Int, oldH: Int)? {
        let oldW = width
        let oldH = height
        let newW = min(oldW * 2, maxEdge)
        let newH = min(oldH * 2, maxEdge)
        if newW <= oldW && newH <= oldH { return nil }
        var next = [UInt8](repeating: 0, count: newW * newH * Self.bpp)
        pixels.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            next.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                let srcRow = oldW * Self.bpp
                let dstRow = newW * Self.bpp
                for y in 0..<oldH {
                    d.advanced(by: y * dstRow).update(from: s.advanced(by: y * srcRow), count: srcRow)
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

    func blit(_ bgra: [UInt8], width w: Int, height h: Int, x: Int, y: Int) {
        bgra.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            pixels.withUnsafeMutableBufferPointer { dst in
                guard let d = dst.baseAddress else { return }
                let srcRow = w * Self.bpp
                let dstRow = width * Self.bpp
                for row in 0..<h {
                    d.advanced(by: (y + row) * dstRow + x * Self.bpp)
                        .update(from: s.advanced(by: row * srcRow), count: srcRow)
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

    public struct Glyph: Sendable {
        public var uv: UV
        public var color: Bool
        public static let empty = Glyph(uv: .empty, color: false)
    }

    public private(set) var texture: MTLTexture
    public private(set) var colorTexture: MTLTexture
    public let cellW: Int
    public let cellH: Int
    public let metrics: CellMetrics
    /// Bumped on `clear()` / `grow()`. Instance UVs from an in-flight expand are stale until retry.
    var packGeneration: Int { shelf.generation &+ colorShelf.generation }

    private var shelf: R8Shelf
    private var colorShelf: BGRAShelf
    private var cache: [UInt64: Glyph] = [:]
    private let device: MTLDevice

    static let maxAtlasEdge = 16384
    static let colorEdge = 512

    public init?(device: MTLDevice, metrics: CellMetrics, edge: Int = 1024) {
        self.device = device
        self.metrics = metrics
        self.cellW = metrics.cellWidthPx
        self.cellH = metrics.cellHeightPx
        let shelf = R8Shelf(edge: edge, maxEdge: Self.maxAtlasEdge)
        self.shelf = shelf
        let colorShelf = BGRAShelf(edge: Self.colorEdge, maxEdge: Self.maxAtlasEdge)
        self.colorShelf = colorShelf
        guard let tex = Self.makeTexture(device: device, width: shelf.width, height: shelf.height) else {
            return nil
        }
        self.texture = tex
        guard let ctex = Self.makeColorTexture(
            device: device, width: colorShelf.width, height: colorShelf.height
        ) else {
            return nil
        }
        self.colorTexture = ctex
    }

    public func uv(scalar: UInt32, bold: Bool, italic: Bool) -> UV {
        glyph(scalar: scalar, bold: bold, italic: italic, wide: false).uv
    }

    public func glyph(
        scalar: UInt32,
        bold: Bool,
        italic: Bool,
        wide: Bool,
        cluster: [UInt32]? = nil
    ) -> Glyph {
        if cluster == nil, (scalar == 0 || scalar == 0x20) { return .empty }
        var key = UInt64(scalar)
            | (bold ? 1 << 32 : 0)
            | (italic ? 1 << 33 : 0)
            | (wide ? 1 << 34 : 0)
        if let cluster, cluster.count > 1 {
            var h: UInt64 = 0xcbf29ce484222325
            for cp in cluster {
                h ^= UInt64(cp)
                h &*= 0x100000001b3
            }
            key ^= h << 8
        }
        if let hit = cache[key] { return hit }
        let g = rasterize(scalar: scalar, bold: bold, italic: italic, wide: wide, cluster: cluster)
        cache[key] = g
        return g
    }

    private func rasterize(
        scalar: UInt32,
        bold: Bool,
        italic: Bool,
        wide: Bool,
        cluster: [UInt32]?
    ) -> Glyph {
        let text: String
        if let cluster, !cluster.isEmpty {
            text = String(cluster.compactMap { UnicodeScalar($0).map { Character($0) } })
        } else if let us = UnicodeScalar(scalar) {
            text = String(Character(us))
        } else {
            return .empty
        }
        guard !text.isEmpty else { return .empty }
        let font = metrics.face(bold: bold, italic: italic)
        let cf = text as CFString
        var used = font
        let fallback = CTFontCreateForString(font, cf, CFRange(location: 0, length: CFStringGetLength(cf)))
        let name = CTFontCopyPostScriptName(fallback) as String
        if !name.contains("LastResort") {
            used = fallback
        }
        if CTFontGetSymbolicTraits(used).contains(.traitColorGlyphs) {
            return rasterizeColor(text: text, font: used, wide: wide)
        }
        return rasterizeGray(text: text, font: used, wide: wide)
    }

    private func rasterizeGray(text: String, font: CTFont, wide: Bool) -> Glyph {
        let w = max(1, wide ? cellW * 2 : cellW)
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
        ctx.textMatrix = .identity
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        let penX = max(0, (CGFloat(w) - CGFloat(advance)) * 0.5)
        ctx.textPosition = CGPoint(x: penX, y: CGFloat(metrics.cellBaselinePx))
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
            return Glyph(uv: writeGray(coverage, width: w, height: h, rect: rect), color: false)
        }
        if growGray(), let rect = shelf.allocate(width: w, height: h) {
            return Glyph(uv: writeGray(coverage, width: w, height: h, rect: rect), color: false)
        }
        clearGray()
        guard let rect = shelf.allocate(width: w, height: h) else { return .empty }
        return Glyph(uv: writeGray(coverage, width: w, height: h, rect: rect), color: false)
    }

    private func rasterizeColor(text: String, font: CTFont, wide: Bool) -> Glyph {
        let boxW = max(1, wide ? cellW * 2 : cellW)
        let boxH = max(1, cellH)
        var chars = Array(text.utf16)
        var gs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, &chars, &gs, chars.count)
        var g = gs.first(where: { $0 != 0 }) ?? 0
        var bounds = CGRect.zero
        if g != 0 {
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &bounds, 1)
        }
        // Ghostty emoji constraint: cover, center, pad_left/right 0.025.
        let padFrac: CGFloat = 0.025
        let availW = CGFloat(boxW) * (1 - 2 * padFrac)
        let availH = CGFloat(boxH)
        let bw = max(bounds.width, 1)
        let bh = max(bounds.height, 1)
        let scale = min(availW / bw, availH / bh)
        let destW = bw * scale
        let destH = bh * scale
        let ox = (CGFloat(boxW) - destW) / 2
        let oy = (CGFloat(boxH) - destH) / 2
        let bpr = boxW * 4
        var bgra = [UInt8](repeating: 0, count: bpr * boxH)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: &bgra,
            width: boxW,
            height: boxH,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return .empty }
        ctx.clear(CGRect(x: 0, y: 0, width: boxW, height: boxH))
        ctx.textMatrix = .identity
        ctx.translateBy(x: ox, y: oy)
        let cluster = text.unicodeScalars.count > 1
        if !cluster, g != 0, bounds.width > 0.5 {
            ctx.scaleBy(x: destW / bounds.width, y: destH / bounds.height)
            var pos = CGPoint(x: -bounds.minX, y: -bounds.minY)
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
        } else {
            ctx.scaleBy(x: destW / bw, y: destH / bh)
            let attrs: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
            CTLineDraw(line, ctx)
        }
        if let rect = colorShelf.allocate(width: boxW, height: boxH) {
            return Glyph(uv: writeColor(bgra, width: boxW, height: boxH, rect: rect), color: true)
        }
        if growColor(), let rect = colorShelf.allocate(width: boxW, height: boxH) {
            return Glyph(uv: writeColor(bgra, width: boxW, height: boxH, rect: rect), color: true)
        }
        return .empty
    }

    private func writeGray(
        _ coverage: [UInt8],
        width w: Int,
        height h: Int,
        rect: (x: Int, y: Int, w: Int, h: Int)
    ) -> UV {
        shelf.blit(coverage, width: w, height: h, x: rect.x, y: rect.y)
        uploadGray(region: MTLRegionMake2D(rect.x, rect.y, rect.w, rect.h))
        let fw = Float(shelf.width)
        let fh = Float(shelf.height)
        return UV(
            u0: Float(rect.x) / fw,
            v0: Float(rect.y) / fh,
            u1: Float(rect.x + w) / fw,
            v1: Float(rect.y + h) / fh
        )
    }

    private func writeColor(
        _ bgra: [UInt8],
        width w: Int,
        height h: Int,
        rect: (x: Int, y: Int, w: Int, h: Int)
    ) -> UV {
        colorShelf.blit(bgra, width: w, height: h, x: rect.x, y: rect.y)
        uploadColor(region: MTLRegionMake2D(rect.x, rect.y, rect.w, rect.h))
        let fw = Float(colorShelf.width)
        let fh = Float(colorShelf.height)
        return UV(
            u0: Float(rect.x) / fw,
            v0: Float(rect.y) / fh,
            u1: Float(rect.x + w) / fw,
            v1: Float(rect.y + h) / fh
        )
    }

    @discardableResult
    private func growGray() -> Bool {
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
        for (key, g) in cache where !g.color {
            cache[key] = Glyph(
                uv: UV(u0: g.uv.u0 * sx, v0: g.uv.v0 * sy, u1: g.uv.u1 * sx, v1: g.uv.v1 * sy),
                color: false
            )
        }
        texture = tex
        uploadGrayFull()
        return true
    }

    @discardableResult
    private func growColor() -> Bool {
        let oldW = colorShelf.width
        let oldH = colorShelf.height
        let newW = min(oldW * 2, Self.maxAtlasEdge)
        let newH = min(oldH * 2, Self.maxAtlasEdge)
        if newW <= oldW && newH <= oldH { return false }
        guard let tex = Self.makeColorTexture(device: device, width: newW, height: newH) else {
            return false
        }
        guard colorShelf.grow() != nil else { return false }
        let sx = Float(oldW) / Float(colorShelf.width)
        let sy = Float(oldH) / Float(colorShelf.height)
        for (key, g) in cache where g.color {
            cache[key] = Glyph(
                uv: UV(u0: g.uv.u0 * sx, v0: g.uv.v0 * sy, u1: g.uv.u1 * sx, v1: g.uv.v1 * sy),
                color: true
            )
        }
        colorTexture = tex
        uploadColorFull()
        return true
    }

    private func clearGray() {
        cache = cache.filter { $0.value.color }
        shelf.clear()
        uploadGrayFull()
    }

    private func uploadGrayFull() {
        texture.replace(
            region: MTLRegionMake2D(0, 0, shelf.width, shelf.height),
            mipmapLevel: 0,
            withBytes: shelf.pixels,
            bytesPerRow: shelf.width
        )
    }

    private func uploadColorFull() {
        colorTexture.replace(
            region: MTLRegionMake2D(0, 0, colorShelf.width, colorShelf.height),
            mipmapLevel: 0,
            withBytes: colorShelf.pixels,
            bytesPerRow: colorShelf.width * BGRAShelf.bpp
        )
    }

    private func uploadGray(region: MTLRegion) {
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

    private func uploadColor(region: MTLRegion) {
        let x = Int(region.origin.x)
        let y = Int(region.origin.y)
        let stride = colorShelf.width * BGRAShelf.bpp
        colorShelf.pixels.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: y * stride + x * BGRAShelf.bpp)
            colorTexture.replace(
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

    private static func makeColorTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }
}
