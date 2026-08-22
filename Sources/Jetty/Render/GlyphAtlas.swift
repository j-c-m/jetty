import CoreGraphics
import CoreText
import Foundation
import Metal

public final class GlyphAtlas {
    public struct UV: Sendable {
        public var u0, v0, u1, v1: Float
        public static let empty = UV(u0: 0, v0: 0, u1: 0, v1: 0)
    }

    public let texture: MTLTexture
    public let cellW: Int
    public let cellH: Int
    public let metrics: CellMetrics

    private let atlasW: Int
    private let atlasH: Int
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    private var cache: [UInt64: UV] = [:]
    private let device: MTLDevice

    public init?(device: MTLDevice, metrics: CellMetrics) {
        self.device = device
        self.metrics = metrics
        self.cellW = metrics.cellWidthPx
        self.cellH = metrics.cellHeightPx
        self.atlasW = 1024
        self.atlasH = 1024
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasW, height: atlasH, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
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
        var pixels = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return .empty }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.textMatrix = .identity

        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: used,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(Character(us)), attributes: attrs))
        ctx.textPosition = CGPoint(x: 0, y: CGFloat(metrics.cellBaselinePx))
        CTLineDraw(line, ctx)

        if shelfX + w > atlasW {
            shelfX = 0
            shelfY += shelfH
            shelfH = 0
        }
        if shelfY + h > atlasH {
            cache.removeAll(keepingCapacity: true)
            shelfX = 0
            shelfY = 0
            shelfH = 0
        }
        let x = shelfX
        let y = shelfY
        texture.replace(
            region: MTLRegionMake2D(x, y, w, h),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: w
        )
        shelfX += w
        shelfH = max(shelfH, h)
        let fw = Float(atlasW)
        let fh = Float(atlasH)
        return UV(
            u0: Float(x) / fw,
            v0: Float(y + h) / fh,
            u1: Float(x + w) / fw,
            v1: Float(y) / fh
        )
    }
}
