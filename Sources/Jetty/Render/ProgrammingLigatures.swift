import CVt

enum ProgrammingLigatures {
    /// JetBrains Mono `calt` ligatures (official list).
    /// https://github.com/JetBrains/JetBrainsMono/wiki/List-of-supported-symbols
    /// Indexed longest-first by first byte at load.
    static let raw: [String] = [
        "--", "---", "==", "===", "!=", "!==", "=!=", "=:=", "=/=",
        "<=", ">=", "&&", "&&&", "&=", "++", "+++", "***", ";;", "!!",
        "??", "???", "?:", "?.", "?=", "<:", ":<", ":>", ">:", "<:<",
        "<>", "<<<", ">>>", "<<", ">>", "||", "-|", "_|_", "|-", "||-",
        "|=", "||=", "##", "###", "####", "#{", "#[", "]#", "#(", "#?",
        "#_", "#_(", "#:", "#!", "#=", "^=", "<$>", "<$", "$>", "<+>",
        "<+", "+>", "<*>", "<*", "*>", "</", "</>", "/>", "<!--",
        "<#--", "-->", "->", "->>", "<<-", "<-", "<=<", "=<<", "<<=",
        "<==", "<=>", "<==>", "==>", "=>", "=>>", ">=>", ">>=", ">>-",
        ">-", "-<", "-<<", ">->", "<-<", "<-|", "<=|", "|=>", "|->",
        "<->", "<<~", "<~~", "<~", "<~>", "~~", "~~>", "~>", "~-",
        "-~", "~@", "[||]", "|]", "[|", "|}", "{|", "[<", ">]", "|>",
        "<|", "||>", "<||", "|||>", "<|||", "<|>", "...", "..", ".=",
        "..<", ".?", "::", ":::", ":=", "::=", ":?", ":?>", "//",
        "///", "/*", "*/", "/=", "//=", "/==", "@_", "__", ";;;",
    ]

    /// `raw` sorted longest first. Tests and docs; the scan uses `byFirst`.
    static let table: [String] = raw.sorted { a, b in
        if a.count != b.count { return a.count > b.count }
        return a < b
    }

    /// `byFirst[b]` is the patterns that start with byte `b`, longest first.
    private static let byFirst: [[[UInt8]]] = {
        var buckets: [[[UInt8]]] = Array(repeating: [], count: 128)
        for s in table {
            let bytes = Array(s.utf8)
            guard let first = bytes.first, first < 128, bytes.count >= 2 else { continue }
            buckets[Int(first)].append(bytes)
        }
        return buckets
    }()

    static func ascii(_ cell: Cell) -> UInt8? {
        let c = cell.content
        if (c & (CONTENT_KIND_MASK | CONTENT_WIDE_MASK)) != 0 { return nil }
        let p = c & CONTENT_PAYLOAD
        if p < 0x20 || p > 0x7E { return nil }
        return UInt8(truncatingIfNeeded: p)
    }

    /// Length of the table hit at `x`, or 0.
    static func spanLength(row: UnsafePointer<Cell>, x: Int, cols: Int) -> Int {
        if x < 0 || x >= cols { return 0 }
        let c0 = row[x].content
        if (c0 & (CONTENT_KIND_MASK | CONTENT_WIDE_MASK)) != 0 { return 0 }
        let p0 = c0 & CONTENT_PAYLOAD
        if p0 < 0x21 || p0 > 0x7E { return 0 }
        let pats = byFirst[Int(p0)]
        var i = 0
        while i < pats.count {
            let pat = pats[i]
            if match(row: row, x: x, cols: cols, pat: pat)
                && !repeatTouchesSame(row: row, x: x, cols: cols, pat: pat)
            {
                return pat.count
            }
            i += 1
        }
        return 0
    }

    /// `===` / `---` / `####` only when the run is exactly `pat` (JetBrains `calt`).
    private static func repeatTouchesSame(
        row: UnsafePointer<Cell>,
        x: Int,
        cols: Int,
        pat: [UInt8]
    ) -> Bool {
        let n = pat.count
        if n == 0 { return false }
        let b = pat[0]
        var i = 1
        while i < n {
            if pat[i] != b { return false }
            i += 1
        }
        if x > 0 {
            let c = row[x - 1].content
            if (c & (CONTENT_KIND_MASK | CONTENT_WIDE_MASK)) == 0
                && (c & CONTENT_PAYLOAD) == UInt32(b)
            {
                return true
            }
        }
        if x + n < cols {
            let c = row[x + n].content
            if (c & (CONTENT_KIND_MASK | CONTENT_WIDE_MASK)) == 0
                && (c & CONTENT_PAYLOAD) == UInt32(b)
            {
                return true
            }
        }
        return false
    }

    /// Bytes of `pat` at `x`, same bold/italic, no wide/grapheme.
    private static func match(
        row: UnsafePointer<Cell>,
        x: Int,
        cols: Int,
        pat: [UInt8]
    ) -> Bool {
        let n = pat.count
        if n == 0 || x + n > cols { return false }
        let style = UInt16(ATTR_BOLD | ATTR_ITALIC)
        let a0 = row[x].attrs & style
        var i = 0
        while i < n {
            let cell = row[x + i]
            let c = cell.content
            if (c & (CONTENT_KIND_MASK | CONTENT_WIDE_MASK)) != 0 { return false }
            if (c & CONTENT_PAYLOAD) != UInt32(pat[i]) { return false }
            if (cell.attrs & style) != a0 { return false }
            i += 1
        }
        return true
    }
}
