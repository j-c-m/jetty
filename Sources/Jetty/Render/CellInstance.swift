import simd

@frozen
public struct CellInstance {
    public var ox: Int16
    public var oy: Int16
    public var sx: UInt16
    public var sy: UInt16
    public var u0: UInt16
    public var v0: UInt16
    public var u1: UInt16
    public var v1: UInt16
    public var fg: UInt32
    public var bg: UInt32
    public var atlas: UInt8
    public var flags: UInt8
    public var _pad0: UInt16
    public var _pad1: UInt32

    public static var stride: Int { MemoryLayout<CellInstance>.stride }
    public static let hasGlyphFlag: UInt8 = 1

    public static let empty = CellInstance(
        originX: 0, originY: 0, width: 0, height: 0,
        uv: GlyphAtlas.UV.empty,
        fgRGB: .zero, bgRGB: .zero,
        colorAtlas: false
    )

    public init(
        originX: Float, originY: Float,
        width: Float, height: Float,
        uv: GlyphAtlas.UV,
        fgRGB: SIMD3<Float>,
        bgRGB: SIMD3<Float>,
        colorAtlas: Bool,
        bgAlpha: Float = 1
    ) {
        ox = Self.i16(originX)
        oy = Self.i16(originY)
        sx = Self.u16(width)
        sy = Self.u16(height)
        u0 = uv.u0
        v0 = uv.v0
        u1 = uv.u1
        v1 = uv.v1
        fg = Self.pack(fgRGB)
        bg = Self.pack(bgRGB, a: bgAlpha)
        atlas = colorAtlas ? 1 : 0
        flags = (uv.u1 > uv.u0 && uv.v1 > uv.v0) ? Self.hasGlyphFlag : 0
        _pad0 = 0
        _pad1 = 0
    }

    public static func pack(_ rgb: SIMD3<Float>, a: Float = 1) -> UInt32 {
        func byte(_ x: Float) -> UInt32 {
            UInt32(min(255, max(0, x * 255)).rounded())
        }
        return byte(rgb.x) | (byte(rgb.y) << 8) | (byte(rgb.z) << 16) | (byte(a) << 24)
    }

    static func i16(_ v: Float) -> Int16 {
        let r = v.rounded()
        if r <= Float(Int16.min) { return .min }
        if r >= Float(Int16.max) { return .max }
        return Int16(r)
    }

    static func u16(_ v: Float) -> UInt16 {
        if v <= 0 { return 0 }
        let r = v.rounded()
        if r >= Float(UInt16.max) { return .max }
        return UInt16(r)
    }
}

@frozen
public struct OverlayInstance {
    public var ox: Float, oy: Float, sx: Float, sy: Float
    public var r: Float, g: Float, b: Float, a: Float

    public static var stride: Int { MemoryLayout<OverlayInstance>.stride }

    public init(ox: Float, oy: Float, sx: Float, sy: Float, r: Float, g: Float, b: Float, a: Float) {
        self.ox = ox
        self.oy = oy
        self.sx = sx
        self.sy = sy
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

@frozen
public struct ImageInstance {
    public var ox: Int16
    public var oy: Int16
    public var sx: UInt16
    public var sy: UInt16
    public var u0: UInt16
    public var v0: UInt16
    public var u1: UInt16
    public var v1: UInt16
    public var _pad0: UInt32
    public var _pad1: UInt32
    public var _pad2: UInt32
    public var _pad3: UInt32

    public static var stride: Int { MemoryLayout<ImageInstance>.stride }

    public init(ox: Int16, oy: Int16, sx: UInt16, sy: UInt16, u0: UInt16, v0: UInt16, u1: UInt16, v1: UInt16) {
        self.ox = ox
        self.oy = oy
        self.sx = sx
        self.sy = sy
        self.u0 = u0
        self.v0 = v0
        self.u1 = u1
        self.v1 = v1
        _pad0 = 0
        _pad1 = 0
        _pad2 = 0
        _pad3 = 0
    }
}

public struct ImageUniforms {
    public var viewportX: Float
    public var viewportY: Float
    public var contentOffsetY: Float
    public var _pad0: Float = 0
    public var texW: Float
    public var texH: Float
    public var _pad1: Float = 0
    public var _pad2: Float = 0
    public static var stride: Int { MemoryLayout<ImageUniforms>.stride }
}

public struct FrameUniforms {
    public var viewportX: Float
    public var viewportY: Float
    public var contentOffsetY: Float = 0
    public var _pad0: Float = 0
    public var atlasW: Float = 1
    public var atlasH: Float = 1
    public var colorAtlasW: Float = 1
    public var colorAtlasH: Float = 1
    public static var stride: Int { MemoryLayout<FrameUniforms>.stride }
}
