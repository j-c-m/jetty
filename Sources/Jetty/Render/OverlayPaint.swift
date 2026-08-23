import CVt
import simd

enum OverlayPaint {
    static func thickness(_ cellH: Float) -> Float {
        max(1, cellH * 0.06)
    }

    static func dashPeriod(ul: UInt16, cellH: Float) -> (on: Float, off: Float)? {
        let t = thickness(cellH)
        let dot = max(1, t * 2)
        if ul == UInt16(UL_DOTTED) { return (dot, dot) }
        if ul == UInt16(UL_DASHED) { return (3 * dot, 2 * dot) }
        return nil
    }

    /// `ceil` the span, then cap at `floor(cellW)`.
    static func dashCount(cellW: Float, on: Float, off: Float) -> Int {
        let period = on + off
        if cellW <= 0 || period <= 0 { return 0 }
        let n = min(Int(ceil(Double(cellW / period))), Int(floor(Double(cellW))))
        return max(n, 0)
    }

    static func count(attrs: UInt16, wide: UInt32, cellW: Float, cellH: Float) -> Int {
        if wide == WIDE_TAIL || wide == WIDE_HEAD { return 0 }
        let ul = attrs & UInt16(ATTR_UL_MASK)
        var n = 0
        if let d = dashPeriod(ul: ul, cellH: cellH) {
            n = dashCount(cellW: cellW, on: d.on, off: d.off)
        } else if ul == UInt16(UL_DOUBLE) {
            n = 2
        } else if ul == UInt16(UL_CURLY) {
            n = 4
        } else if ul != 0 {
            n = 1
        }
        if (attrs & UInt16(ATTR_STRIKETHROUGH)) != 0 { n += 1 }
        if (attrs & UInt16(ATTR_OVERLINE)) != 0 { n += 1 }
        return n
    }

    @discardableResult
    static func write(
        cell: Cell,
        ox: Float,
        oy: Float,
        cellW: Float,
        cellH: Float,
        palette: UnsafePointer<SIMD3<Float>>,
        defFG: SIMD3<Float>,
        defBG: SIMD3<Float>,
        ulColor: UInt32?,
        dest: UnsafeMutablePointer<OverlayInstance>,
        at: Int
    ) -> Int {
        let wide = cell.content & CONTENT_WIDE_MASK
        if wide == WIDE_TAIL || wide == WIDE_HEAD { return 0 }
        var fg = GridExpand.resolve(cell.fg, palette: palette, def: defFG)
        var bg = GridExpand.resolve(cell.bg, palette: palette, def: defBG)
        if (cell.attrs & UInt16(ATTR_REVERSE)) != 0 { swap(&fg, &bg) }
        var ulRGB = fg
        if let packed = ulColor, PackedColor.type(of: packed) == 2 {
            let rgb = RGB.packed(packed)
            ulRGB = SIMD3(Float(rgb.r) / 255, Float(rgb.g) / 255, Float(rgb.b) / 255)
        }
        let t = thickness(cellH)
        let ul = cell.attrs & UInt16(ATTR_UL_MASK)
        var w = 0
        func quad(_ x: Float, _ y: Float, _ sx: Float, _ sy: Float, _ c: SIMD3<Float>) {
            dest[at + w] = OverlayInstance(
                ox: x, oy: y, sx: sx, sy: sy, r: c.x, g: c.y, b: c.z, a: 1
            )
            w += 1
        }
        let base = oy + cellH - t * 2
        if let d = dashPeriod(ul: ul, cellH: cellH) {
            let n = dashCount(cellW: cellW, on: d.on, off: d.off)
            var x: Float = 0
            var i = 0
            while i < n {
                let sx = min(d.on, cellW - x)
                if sx > 0 { quad(ox + x, base, sx, t, ulRGB) }
                x += d.on + d.off
                i += 1
            }
        } else if ul == UInt16(UL_DOUBLE) {
            quad(ox, base, cellW, t, ulRGB)
            quad(ox, base - t * 2, cellW, t, ulRGB)
        } else if ul == UInt16(UL_CURLY) {
            let seg = cellW / 4
            quad(ox, base, seg, t, ulRGB)
            quad(ox + seg, base - t * 2, seg, t, ulRGB)
            quad(ox + seg * 2, base, seg, t, ulRGB)
            quad(ox + seg * 3, base - t * 2, cellW - seg * 3, t, ulRGB)
        } else if ul != 0 {
            quad(ox, base, cellW, t, ulRGB)
        }
        if (cell.attrs & UInt16(ATTR_STRIKETHROUGH)) != 0 {
            quad(ox, oy + cellH * 0.55, cellW, t, fg)
        }
        if (cell.attrs & UInt16(ATTR_OVERLINE)) != 0 {
            quad(ox, oy + 1, cellW, t, fg)
        }
        return w
    }
}
