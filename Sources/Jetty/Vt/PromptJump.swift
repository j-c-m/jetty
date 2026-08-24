/// OSC 133 prompt starts. Jump uses `{A,P,L}` only.
enum PromptJump {
    static func isPromptStart(_ action: UInt8) -> Bool {
        action == UInt8(ascii: "A")
            || action == UInt8(ascii: "P")
            || action == UInt8(ascii: "L")
    }

    /// Previous (`dir < 0`) or next (`dir > 0`) prompt line in the live document.
    /// Marks with `line < linesScrolled - sbLen` or `line >= linesScrolled + rows` are skipped.
    static func target(
        marks: [(line: UInt64, action: UInt8)],
        dir: Int,
        linesScrolled: UInt64,
        sbLen: Int,
        rows: Int,
        integerRow: Int
    ) -> UInt64? {
        if rows <= 0 || dir == 0 { return nil }
        let sb = max(0, sbLen)
        let lo = linesScrolled >= UInt64(sb) ? linesScrolled - UInt64(sb) : 0
        let hi = linesScrolled &+ UInt64(rows)
        let top = lo &+ UInt64(max(0, integerRow))
        var best: UInt64?
        for m in marks {
            if !isPromptStart(m.action) { continue }
            if m.line < lo || m.line >= hi { continue }
            if dir < 0 {
                if m.line < top, best == nil || m.line > best! { best = m.line }
            } else if m.line > top, best == nil || m.line < best! {
                best = m.line
            }
        }
        return best
    }

    static func docRow(line: UInt64, linesScrolled: UInt64, sbLen: Int) -> Int {
        let sb = max(0, sbLen)
        let lo = linesScrolled >= UInt64(sb) ? linesScrolled - UInt64(sb) : 0
        if line <= lo { return 0 }
        let d = line - lo
        if d > UInt64(Int.max) { return Int.max }
        return Int(d)
    }
}
