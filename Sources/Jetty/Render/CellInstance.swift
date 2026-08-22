@frozen
public struct CellInstance {
    public var ox: Float, oy: Float, sx: Float, sy: Float
    public var u0: Float, v0: Float, u1: Float, v1: Float
    public var fr: Float, fg: Float, fb: Float, fa: Float
    public var br: Float, bg: Float, bb: Float, ba: Float
    public var atlas: Float
    public var _pad0: Float
    public var _pad1: Float
    public var _pad2: Float

    public static let floatCount = 20
    public static var stride: Int { MemoryLayout<CellInstance>.stride }

    public static func make(
        originX: Float, originY: Float,
        width: Float, height: Float,
        u0: Float, v0: Float, u1: Float, v1: Float,
        fr: Float, fg: Float, fb: Float, fa: Float,
        br: Float, bg: Float, bb: Float, ba: Float
    ) -> CellInstance {
        CellInstance(
            ox: originX, oy: originY, sx: width, sy: height,
            u0: u0, v0: v0, u1: u1, v1: v1,
            fr: fr, fg: fg, fb: fb, fa: fa,
            br: br, bg: bg, bb: bb, ba: ba,
            atlas: 0, _pad0: 0, _pad1: 0, _pad2: 0
        )
    }

    public func write(to buf: UnsafeMutablePointer<Float>, at index: Int) {
        withUnsafeBytes(of: self) { src in
            let dest = UnsafeMutableRawPointer(buf + index * Self.floatCount)
            dest.copyMemory(from: src.baseAddress!, byteCount: Self.stride)
        }
    }
}

@frozen
public struct OverlayInstance {
    public var ox: Float, oy: Float, sx: Float, sy: Float
    public var r: Float, g: Float, b: Float, a: Float

    public static let floatCount = 8
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

public struct FrameUniforms {
    public var viewportX: Float
    public var viewportY: Float
    public var contentOffsetY: Float = 0
    public var _pad1: Float = 0
    public static var stride: Int { 4 * MemoryLayout<Float>.size }
}
