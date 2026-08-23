import CoreText
import CVt

struct LigaSpan {
    var row: Int
    var x: Int
    var n: Int
    var text: String
    var bold: Bool
    var italic: Bool
}

enum LigatureExpand {
    static func collect(
        cells: UnsafePointer<Cell>,
        cols: Int,
        rows: Int,
        mode: AppConfig.Ligatures,
        shaper: ShaperCache,
        font: (Bool, Bool) -> CTFont,
        fontPx: Int,
        feature: String,
        hide: UnsafeMutablePointer<UInt8>
    ) -> [LigaSpan] {
        let count = cols * rows
        for i in 0..<count { hide[i] = 0 }
        if mode == .off || cols <= 0 || rows <= 0 { return [] }
        var spans: [LigaSpan] = []
        var y = 0
        while y < rows {
            let row = cells + y * cols
            if mode == .programming {
                scanProgramming(
                    row: row, y: y, cols: cols, shaper: shaper, font: font,
                    fontPx: fontPx, feature: feature, hide: hide, spans: &spans
                )
            } else {
                scanOn(
                    row: row, y: y, cols: cols, shaper: shaper, font: font,
                    fontPx: fontPx, feature: feature, hide: hide, spans: &spans
                )
            }
            y += 1
        }
        return spans
    }

    private static func scanProgramming(
        row: UnsafePointer<Cell>,
        y: Int,
        cols: Int,
        shaper: ShaperCache,
        font: (Bool, Bool) -> CTFont,
        fontPx: Int,
        feature: String,
        hide: UnsafeMutablePointer<UInt8>,
        spans: inout [LigaSpan]
    ) {
        var x = 0
        while x < cols {
            let n = ProgrammingLigatures.spanLength(row: row, x: x, cols: cols)
            if n <= 0 {
                x += 1
                continue
            }
            if let span = confirm(
                row: row, y: y, x: x, n: n, cols: cols, shaper: shaper, font: font,
                fontPx: fontPx, feature: feature, hide: hide
            ) {
                spans.append(span)
            }
            x += n
        }
    }

    private static func scanOn(
        row: UnsafePointer<Cell>,
        y: Int,
        cols: Int,
        shaper: ShaperCache,
        font: (Bool, Bool) -> CTFont,
        fontPx: Int,
        feature: String,
        hide: UnsafeMutablePointer<UInt8>,
        spans: inout [LigaSpan]
    ) {
        var x = 0
        while x < cols {
            let nProg = ProgrammingLigatures.spanLength(row: row, x: x, cols: cols)
            if nProg > 0 {
                if let span = confirm(
                    row: row, y: y, x: x, n: nProg, cols: cols, shaper: shaper, font: font,
                    fontPx: fontPx, feature: feature, hide: hide
                ) {
                    spans.append(span)
                }
                x += nProg
                continue
            }
            guard runChar(row[x]) != nil else {
                x += 1
                continue
            }
            let bold = (row[x].attrs & UInt16(ATTR_BOLD)) != 0
            let italic = (row[x].attrs & UInt16(ATTR_ITALIC)) != 0
            var end = x + 1
            while end < cols {
                guard runChar(row[end]) != nil else { break }
                if ((row[end].attrs & UInt16(ATTR_BOLD)) != 0) != bold { break }
                if ((row[end].attrs & UInt16(ATTR_ITALIC)) != 0) != italic { break }
                if ProgrammingLigatures.spanLength(row: row, x: end, cols: cols) > 0 { break }
                end += 1
            }
            let n = end - x
            if n >= 2 {
                emitShaped(
                    row: row, y: y, x: x, n: n, cols: cols, shaper: shaper, font: font,
                    fontPx: fontPx, feature: feature, hide: hide, spans: &spans
                )
            }
            x = end
        }
    }

    private static func runChar(_ cell: Cell) -> UInt32? {
        if let a = ProgrammingLigatures.ascii(cell) { return UInt32(a) }
        if (cell.content & CONTENT_KIND_MASK) != CONTENT_SCALAR { return nil }
        if (cell.content & CONTENT_WIDE_MASK) != WIDE_NARROW { return nil }
        let p = cell.contentPayload
        if p < 0x20 { return p == 0 ? 0x20 : nil }
        if SpriteFace.covers(p) { return nil }
        return p
    }

    private static func confirm(
        row: UnsafePointer<Cell>,
        y: Int,
        x: Int,
        n: Int,
        cols: Int,
        shaper: ShaperCache,
        font: (Bool, Bool) -> CTFont,
        fontPx: Int,
        feature: String,
        hide: UnsafeMutablePointer<UInt8>
    ) -> LigaSpan? {
        let text = rowText(row: row, x: x, n: n)
        let bold = (row[x].attrs & UInt16(ATTR_BOLD)) != 0
        let italic = (row[x].attrs & UInt16(ATTR_ITALIC)) != 0
        let face = shaper.featuredFont(font(bold, italic), feature: feature)
        let shaped = shaper.shape(text: text, font: face, fontPx: fontPx)
        guard ShaperCache.isLigature(shaped, text: text, font: face) else { return nil }
        markHide(hide, y: y, x: x, n: n, cols: cols)
        return LigaSpan(row: y, x: x, n: n, text: text, bold: bold, italic: italic)
    }

    /// `on` only: hide consecutive cmap-mismatched cells, not the whole run.
    private static func emitShaped(
        row: UnsafePointer<Cell>,
        y: Int,
        x: Int,
        n: Int,
        cols: Int,
        shaper: ShaperCache,
        font: (Bool, Bool) -> CTFont,
        fontPx: Int,
        feature: String,
        hide: UnsafeMutablePointer<UInt8>,
        spans: inout [LigaSpan]
    ) {
        let text = rowText(row: row, x: x, n: n)
        let bold = (row[x].attrs & UInt16(ATTR_BOLD)) != 0
        let italic = (row[x].attrs & UInt16(ATTR_ITALIC)) != 0
        let face = shaper.featuredFont(font(bold, italic), feature: feature)
        let shaped = shaper.shape(text: text, font: face, fontPx: fontPx)
        let cmap = ShaperCache.cmapGlyphs(text: text, font: face)
        let mask = ShaperCache.ligatedMask(shaped, cells: n, cmap: cmap)
        let chars = Array(text)
        var i = 0
        while i < n {
            if !mask[i] {
                i += 1
                continue
            }
            var j = i + 1
            while j < n && mask[j] { j += 1 }
            if j - i >= 2 {
                let piece = String(chars[i..<j])
                markHide(hide, y: y, x: x + i, n: j - i, cols: cols)
                spans.append(LigaSpan(
                    row: y, x: x + i, n: j - i, text: piece, bold: bold, italic: italic
                ))
            }
            i = j
        }
    }

    private static func rowText(row: UnsafePointer<Cell>, x: Int, n: Int) -> String {
        var text = ""
        text.reserveCapacity(n)
        for i in 0..<n {
            let p = row[x + i].contentPayload
            if p == 0 {
                text.append(" ")
            } else if let u = UnicodeScalar(p) {
                text.append(Character(u))
            } else {
                text.append(" ")
            }
        }
        return text
    }

    private static func markHide(
        _ hide: UnsafeMutablePointer<UInt8>,
        y: Int,
        x: Int,
        n: Int,
        cols: Int
    ) {
        let base = y * cols + x
        for i in 0..<n { hide[base + i] = 1 }
    }
}
