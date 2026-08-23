import CVt
import simd

public enum GridExpand {
    public static func fillPalette(
        _ packed: UnsafePointer<UInt32>,
        reverseVideo: Bool,
        dest: UnsafeMutablePointer<SIMD3<Float>>
    ) {
        var i = 0
        while i < 256 {
            var r = Float((packed[i] >> 16) & 0xFF) * (1.0 / 255.0)
            var g = Float((packed[i] >> 8) & 0xFF) * (1.0 / 255.0)
            var b = Float(packed[i] & 0xFF) * (1.0 / 255.0)
            if reverseVideo {
                r = 1 - r
                g = 1 - g
                b = 1 - b
            }
            dest[i] = SIMD3(r, g, b)
            i += 1
        }
    }

    public static func resolve(
        _ c: UInt32,
        palette: UnsafePointer<SIMD3<Float>>,
        def: SIMD3<Float>
    ) -> SIMD3<Float> {
        let t = c >> 24
        if t == 0 { return def }
        if t == 1 { return palette[Int(c & 0xFF)] }
        let r = Float((c >> 16) & 0xFF) * (1.0 / 255.0)
        let g = Float((c >> 8) & 0xFF) * (1.0 / 255.0)
        let b = Float(c & 0xFF) * (1.0 / 255.0)
        return SIMD3(r, g, b)
    }

    public static func expandRow(
        rowCells: UnsafePointer<Cell>,
        cols: Int,
        rowY: Int,
        cellW: Float,
        cellH: Float,
        originX: Float,
        originY: Float,
        palette: UnsafePointer<SIMD3<Float>>,
        defFG: SIMD3<Float>,
        defBG: SIMD3<Float>,
        atlas: GlyphAtlas,
        cursorX: Int,
        cursorY: Int,
        cursorVisible: Bool,
        blinkOff: Bool = false,
        selection: (x0: Int, y0: Int, x1: Int, y1: Int)?,
        graphemes: [UInt32: [UInt32]] = [:],
        dest: UnsafeMutablePointer<CellInstance>
    ) {
        let selCols = selection.flatMap { CellSelection.columns($0, row: rowY, cols: cols) }
        let cursorOnRow = cursorVisible && rowY == cursorY
        let oy = originY + Float(rowY) * cellH
        var x = 0
        var ox = originX
        while x < cols {
            let cell = rowCells[x]
            var fg = resolve(cell.fg, palette: palette, def: defFG)
            var bg = resolve(cell.bg, palette: palette, def: defBG)
            let reverse = (cell.attrs & UInt16(ATTR_REVERSE)) != 0
            if reverse { swap(&fg, &bg) }
            if let sel = selCols, x >= sel.lo, x <= sel.hi { swap(&fg, &bg) }
            if cursorOnRow && x == cursorX { swap(&fg, &bg) }
            if (cell.attrs & UInt16(ATTR_HIDDEN)) != 0
                || (blinkOff && (cell.attrs & UInt16(ATTR_BLINK)) != 0)
            { fg = bg }
            if (cell.attrs & UInt16(ATTR_DIM)) != 0 {
                fg = fg * (2.0 / 3.0)
            }
            let wide = cell.content & CONTENT_WIDE_MASK
            var g = GlyphAtlas.Glyph.empty
            var sx = cellW
            var sy = cellH
            if wide == WIDE_TAIL {
                sx = 0
                sy = 0
            } else if wide != WIDE_HEAD {
                let bold = (cell.attrs & UInt16(ATTR_BOLD)) != 0
                let italic = (cell.attrs & UInt16(ATTR_ITALIC)) != 0
                let isWide = wide == WIDE_FULL && x + 1 < cols
                if isWide { sx = cellW * 2 }
                if (cell.content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME,
                   let cps = graphemes[cell.contentPayload] {
                    g = atlas.glyph(
                        scalar: cps.first ?? 0, bold: bold, italic: italic, wide: isWide, cluster: cps
                    )
                } else {
                    g = atlas.glyph(
                        scalar: cell.contentPayload, bold: bold, italic: italic, wide: isWide
                    )
                }
            }
            dest[x] = CellInstance(
                ox: ox, oy: oy, sx: sx, sy: sy,
                u0: g.uv.u0, v0: g.uv.v0, u1: g.uv.u1, v1: g.uv.v1,
                fr: fg.x, fg: fg.y, fb: fg.z, fa: 1,
                br: bg.x, bg: bg.y, bb: bg.z, ba: 1,
                atlas: g.color ? 1 : 0, _pad0: 0, _pad1: 0, _pad2: 0
            )
            x += 1
            ox += cellW
        }
    }

    public static func expand(
        cells: UnsafePointer<Cell>,
        cols: Int,
        rows: Int,
        cellW: Float,
        cellH: Float,
        originX: Float,
        originY: Float,
        palette: UnsafePointer<SIMD3<Float>>,
        defFG: SIMD3<Float>,
        defBG: SIMD3<Float>,
        atlas: GlyphAtlas,
        cursorX: Int,
        cursorY: Int,
        cursorVisible: Bool,
        blinkOff: Bool = false,
        selection: (x0: Int, y0: Int, x1: Int, y1: Int)?,
        graphemes: [UInt32: [UInt32]] = [:],
        dest: UnsafeMutablePointer<CellInstance>
    ) {
        var y = 0
        while y < rows {
            expandRow(
                rowCells: cells + y * cols,
                cols: cols,
                rowY: y,
                cellW: cellW,
                cellH: cellH,
                originX: originX,
                originY: originY,
                palette: palette,
                defFG: defFG,
                defBG: defBG,
                atlas: atlas,
                cursorX: cursorX,
                cursorY: cursorY,
                cursorVisible: cursorVisible,
                blinkOff: blinkOff,
                selection: selection,
                graphemes: graphemes,
                dest: dest + y * cols
            )
            y += 1
        }
    }
}

enum CellSelection {
    static func columns(
        _ s: (x0: Int, y0: Int, x1: Int, y1: Int),
        row: Int,
        cols: Int
    ) -> (lo: Int, hi: Int)? {
        var a = (x: s.x0, y: s.y0)
        var b = (x: s.x1, y: s.y1)
        if a.y > b.y || (a.y == b.y && a.x > b.x) { swap(&a, &b) }
        if row < a.y || row > b.y { return nil }
        if a.y == b.y { return (min(a.x, b.x), max(a.x, b.x)) }
        if row == a.y { return (a.x, cols - 1) }
        if row == b.y { return (0, b.x) }
        return (0, cols - 1)
    }
}
