import CVt

enum ProgrammingLigatures {
    /// Longest first. Narrow ASCII only.
    static let table: [String] = {
        let raw = [
            "!==", "===", "==", "!=",
            "<=", ">=", "=>", "->", "<-",
            "::", "//", "/*", "*/",
            "++", "--", "&&", "||", "??",
            ":=",
        ]
        return raw.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a < b
        }
    }()

    static func ascii(_ cell: Cell) -> UInt8? {
        if (cell.content & CONTENT_KIND_MASK) != CONTENT_SCALAR { return nil }
        if (cell.content & CONTENT_WIDE_MASK) != WIDE_NARROW { return nil }
        let p = cell.contentPayload
        if p < 0x20 || p > 0x7E { return nil }
        if SpriteFace.covers(p) { return nil }
        return UInt8(truncatingIfNeeded: p)
    }

    /// Bytes of `pat` at `x`, same bold/italic, no sprite/wide/grapheme.
    static func match(
        row: UnsafePointer<Cell>,
        x: Int,
        cols: Int,
        pat: String
    ) -> Bool {
        let n = pat.utf8.count
        if n == 0 || x < 0 || x + n > cols { return false }
        let a0 = row[x].attrs & UInt16(ATTR_BOLD | ATTR_ITALIC)
        var i = 0
        for b in pat.utf8 {
            if ProgrammingLigatures.ascii(row[x + i]) != b { return false }
            if (row[x + i].attrs & UInt16(ATTR_BOLD | ATTR_ITALIC)) != a0 { return false }
            i += 1
        }
        return true
    }

    /// Length of the table hit at `x`, or 0.
    static func spanLength(row: UnsafePointer<Cell>, x: Int, cols: Int) -> Int {
        for pat in table {
            if match(row: row, x: x, cols: cols, pat: pat) { return pat.utf8.count }
        }
        return 0
    }
}
