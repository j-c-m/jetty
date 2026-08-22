import CVt

public enum PackedColor {
    public static var `default`: UInt32 { COLOR_DEFAULT }

    public static func indexed(_ index: UInt8) -> UInt32 {
        COLOR_INDEXED | UInt32(index)
    }

    public static func rgb(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
        COLOR_RGB | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    public static func type(of c: UInt32) -> UInt32 {
        c >> COLOR_TYPE_SHIFT
    }

    public static func payload(of c: UInt32) -> UInt32 {
        c & COLOR_PAYLOAD
    }
}

extension Cell {
    public static var empty: Cell {
        Cell(content: 0, fg: 0, bg: 0, attrs: 0, extra: 0)
    }

    public var colorTypeFG: UInt32 { PackedColor.type(of: fg) }
    public var colorTypeBG: UInt32 { PackedColor.type(of: bg) }

    public var indexedFG: UInt8? {
        colorTypeFG == 1 ? UInt8(truncatingIfNeeded: PackedColor.payload(of: fg)) : nil
    }

    public var indexedBG: UInt8? {
        colorTypeBG == 1 ? UInt8(truncatingIfNeeded: PackedColor.payload(of: bg)) : nil
    }

    public var wide: UInt32 {
        content & CONTENT_WIDE_MASK
    }

    public var contentKind: UInt32 {
        content & CONTENT_KIND_MASK
    }

    public var contentPayload: UInt32 {
        content & CONTENT_PAYLOAD
    }
}
