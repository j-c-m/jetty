import Foundation

/// OSC 133 `C`…`D` command output span. Jump still uses `{A,P,L}` only.
public enum CommandOutput {
    public static func isOutputEnd(_ action: UInt8) -> Bool {
        action == UInt8(ascii: "D")
            || action == UInt8(ascii: "A")
            || action == UInt8(ascii: "P")
            || action == UInt8(ascii: "L")
            || action == UInt8(ascii: "C")
    }

    /// Exclusive end line. `nil` if `doc` is not inside a `C` span.
    public static func span(
        marks: [(line: UInt64, action: UInt8)],
        at doc: UInt64,
        liveEnd: UInt64
    ) -> (start: UInt64, end: UInt64)? {
        var start: UInt64?
        for m in marks {
            if m.action == UInt8(ascii: "C"), m.line <= doc {
                start = m.line
            }
        }
        guard let lo = start else { return nil }
        var hi = liveEnd
        var seenC = false
        for m in marks {
            if m.action == UInt8(ascii: "C"), m.line == lo {
                seenC = true
                continue
            }
            if seenC, isOutputEnd(m.action), m.line >= lo {
                hi = m.line
                break
            }
        }
        if doc < lo || doc >= hi { return nil }
        if hi <= lo { return nil }
        return (lo, hi)
    }

    public static func liveY(doc: UInt64, linesScrolled: UInt64) -> Int {
        let s = Int64(bitPattern: linesScrolled)
        let d = Int64(bitPattern: doc)
        let y = d - s
        if y > Int64(Int.max) { return Int.max }
        if y < Int64(Int.min) { return Int.min }
        return Int(y)
    }

    public static func docLine(liveY: Int, linesScrolled: UInt64) -> UInt64 {
        if liveY >= 0 {
            return linesScrolled &+ UInt64(liveY)
        }
        let back = UInt64(-liveY)
        if back > linesScrolled { return 0 }
        return linesScrolled - back
    }

    /// `opts` from `jt_osc` starts with the action byte (`D;0;…`).
    public static func exitCode(opts: [UInt8]) -> UInt8? {
        guard opts.count >= 3, opts[1] == UInt8(ascii: ";") else { return nil }
        var i = 2
        var v = 0
        var any = false
        while i < opts.count {
            let b = opts[i]
            if b < UInt8(ascii: "0") || b > UInt8(ascii: "9") { break }
            any = true
            v = v * 10 + Int(b - UInt8(ascii: "0"))
            if v > 255 { return 255 }
            i += 1
        }
        return any ? UInt8(v) : nil
    }
}
