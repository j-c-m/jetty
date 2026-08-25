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
        let maxCol = trailingEnd(row: row, cols: cols)
        var x = 0
        while x < maxCol {
            guard runChar(row[x]) != nil else {
                x += 1
                continue
            }
            let bold = (row[x].attrs & UInt16(ATTR_BOLD)) != 0
            let italic = (row[x].attrs & UInt16(ATTR_ITALIC)) != 0
            let style = runStyle(row[x])
            var digest = ShaperCache.fnvOffset
            ShaperCache.mixCell(&digest, cp: row[x].contentPayload, cluster: 0)
            var end = x + 1
            while end < maxCol {
                guard runChar(row[end]) != nil else { break }
                if ((row[end].attrs & UInt16(ATTR_BOLD)) != 0) != bold { break }
                if ((row[end].attrs & UInt16(ATTR_ITALIC)) != 0) != italic { break }
                if runStyle(row[end]) != style { break }
                if isBadLigaturePair(prev: row[end - 1], next: row[end]) { break }
                ShaperCache.mixCell(&digest, cp: row[end].contentPayload, cluster: end - x)
                end += 1
            }
            let n = end - x
            ShaperCache.mix(&digest, UInt64(n))
            if n >= 2 {
                emitShaped(
                    row: row, y: y, x: x, n: n, cols: cols, contentHash: digest,
                    shaper: shaper, font: font, fontPx: fontPx, feature: feature,
                    hide: hide, spans: &spans
                )
            }
            x = end
        }
    }

    /// Bg is per-cell paint, so it must not split a run.
    private struct RunStyle: Equatable {
        var fg: UInt32
        var ul: UInt16
        var faint: Bool
    }

    private static func runStyle(_ cell: Cell) -> RunStyle {
        RunStyle(
            fg: cell.fg,
            ul: cell.attrs & UInt16(ATTR_UL_MASK),
            faint: (cell.attrs & UInt16(ATTR_DIM)) != 0
        )
    }

    private static func trailingEnd(row: UnsafePointer<Cell>, cols: Int) -> Int {
        var n = cols
        while n > 0 {
            let c = row[n - 1]
            if (c.content & (CONTENT_KIND_MASK | CONTENT_WIDE_MASK)) != 0 { break }
            if (c.content & CONTENT_PAYLOAD) != 0 { break }
            n -= 1
        }
        return n
    }

    /// `fi` / `fl` / `st` must not share a shaped run (plain lowercase).
    private static func isBadLigaturePair(prev: Cell, next: Cell) -> Bool {
        guard let a = ProgrammingLigatures.ascii(prev),
              let b = ProgrammingLigatures.ascii(next) else { return false }
        switch a {
        case 0x66 where b == 0x69 || b == 0x6C: return true // f i, f l
        case 0x73 where b == 0x74: return true // s t
        default: return false
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
        let bold = (row[x].attrs & UInt16(ATTR_BOLD)) != 0
        let italic = (row[x].attrs & UInt16(ATTR_ITALIC)) != 0
        let face = shaper.featuredFont(font(bold, italic), feature: feature)
        let hash = ShaperCache.hashCells(row: row, start: x, count: n)
        let run = shaper.shape(
            row: row, start: x, count: n, contentHash: hash, font: face,
            fontPx: fontPx, bold: bold, italic: italic, feature: feature
        )
        guard run.ligated.contains(true) else { return nil }
        markHide(hide, y: y, x: x, n: n, cols: cols)
        return LigaSpan(
            row: y, x: x, n: n, text: rowText(row: row, x: x, n: n),
            bold: bold, italic: italic
        )
    }

    /// `on` only: hide consecutive cmap-mismatched cells, not the whole run.
    private static func emitShaped(
        row: UnsafePointer<Cell>,
        y: Int,
        x: Int,
        n: Int,
        cols: Int,
        contentHash: UInt64,
        shaper: ShaperCache,
        font: (Bool, Bool) -> CTFont,
        fontPx: Int,
        feature: String,
        hide: UnsafeMutablePointer<UInt8>,
        spans: inout [LigaSpan]
    ) {
        let bold = (row[x].attrs & UInt16(ATTR_BOLD)) != 0
        let italic = (row[x].attrs & UInt16(ATTR_ITALIC)) != 0
        let face = shaper.featuredFont(font(bold, italic), feature: feature)
        let run = shaper.shape(
            row: row, start: x, count: n, contentHash: contentHash, font: face,
            fontPx: fontPx, bold: bold, italic: italic, feature: feature
        )
        let mask = run.ligated
        var i = 0
        while i < n {
            if i >= mask.count || !mask[i] {
                i += 1
                continue
            }
            var j = i + 1
            while j < n && j < mask.count && mask[j] { j += 1 }
            if j - i >= 2 {
                markHide(hide, y: y, x: x + i, n: j - i, cols: cols)
                spans.append(LigaSpan(
                    row: y, x: x + i, n: j - i,
                    text: rowText(row: row, x: x + i, n: j - i),
                    bold: bold, italic: italic
                ))
            }
            i = j
        }
    }

    private static func rowText(row: UnsafePointer<Cell>, x: Int, n: Int) -> String {
        ShaperCache.textFromCells(row: row, start: x, count: n).text
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
