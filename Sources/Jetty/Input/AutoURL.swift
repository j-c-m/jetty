import CVt
import Foundation

/// Hover-time URL detect. Not on the print path.
public enum AutoURL {
    public struct Span: Equatable {
        public var y: Int
        public var x0: Int
        public var x1: Int
    }

    public struct Hit: Equatable {
        public var url: URL
        public var spans: [Span]
        public var osc8: Bool
    }

    /// Live `(x, y)` (history `y < 0`). OSC 8 URI on the cell wins. Wrap-joins ±1.
    public static func hover(screen: Screen, x: Int, y: Int, detect: Bool) -> Hit? {
        let minY = -screen.viewportHistoryCount
        let maxY = screen.rows - 1
        guard x >= 0, x < screen.cols, y >= minY, y <= maxY else { return nil }
        if let uri = screen.uri(at: x, y: y) {
            guard let url = LinkURL.openable(uri) else { return nil }
            let extra = extraAt(screen, x: x, y: y)
            return Hit(
                url: url,
                spans: connectedExtraSpans(screen: screen, x: x, y: y, extra: extra),
                osc8: true
            )
        }
        guard detect else { return nil }
        return detectHit(screen: screen, x: x, y: y)
    }

    private static func detectHit(screen: Screen, x: Int, y: Int) -> Hit? {
        guard let detector = detector() else { return nil }
        let range = wrapJoin(screen, y: y)
        var text = ""
        var map: [(Int, Int)] = []
        for ry in range {
            appendRow(screen, y: ry, text: &text, map: &map)
        }
        guard !text.isEmpty, !map.isEmpty else { return nil }
        let nsLen = (text as NSString).length
        var found: Hit?
        detector.enumerateMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsLen)
        ) { result, _, stop in
            guard found == nil, let result, result.range.location != NSNotFound else { return }
            let r = result.range
            guard r.length > 0, covers(x: x, y: y, range: r, map: map) else { return }
            let raw = (text as NSString).substring(with: r)
            guard let url = result.url.flatMap({ LinkURL.openable($0.absoluteString) })
                ?? LinkURL.openable(raw)
            else { return }
            found = Hit(url: url, spans: spans(range: r, map: map), osc8: false)
            stop.pointee = true
        }
        return found
    }

    private static func detector() -> NSDataDetector? {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }

    private static func wrapJoin(_ screen: Screen, y: Int) -> ClosedRange<Int> {
        let minY = -screen.viewportHistoryCount
        let maxY = max(minY, screen.rows - 1)
        var lo = y
        var hi = y
        if y > minY, screen.isDocumentWrapped(y - 1) { lo = y - 1 }
        if y < maxY, screen.isDocumentWrapped(y) { hi = y + 1 }
        return lo...hi
    }

    private static func rowCells(_ screen: Screen, _ liveY: Int) -> [Cell] {
        if liveY >= 0 {
            guard liveY < screen.rows else { return [] }
            return screen.row(liveY)
        }
        let hi = screen.viewportHistoryCount + liveY
        guard hi >= 0 else { return [] }
        return screen.historyRow(hi)
    }

    private static func extraAt(_ screen: Screen, x: Int, y: Int) -> UInt16 {
        let row = rowCells(screen, y)
        guard x >= 0, x < row.count else { return 0 }
        return row[x].extra
    }

    private static func connectedExtraSpans(
        screen: Screen, x: Int, y: Int, extra: UInt16
    ) -> [Span] {
        let range = wrapJoin(screen, y: y)
        let cols = screen.cols
        var cells: [(y: Int, x: Int, extra: UInt16)] = []
        for ry in range {
            let row = rowCells(screen, ry)
            var c = 0
            while c < cols {
                let e = c < row.count ? row[c].extra : 0
                cells.append((ry, c, e))
                c += 1
            }
        }
        guard extra != 0, let i = cells.firstIndex(where: { $0.y == y && $0.x == x }) else {
            return [Span(y: y, x0: x, x1: x)]
        }
        var lo = i
        while lo > 0, cells[lo - 1].extra == extra { lo -= 1 }
        var hi = i
        while hi + 1 < cells.count, cells[hi + 1].extra == extra { hi += 1 }
        var out: [Span] = []
        var p = lo
        while p <= hi {
            let ry = cells[p].y
            let x0 = cells[p].x
            var x1 = x0
            p += 1
            while p <= hi, cells[p].y == ry {
                x1 = cells[p].x
                p += 1
            }
            out.append(Span(y: ry, x0: x0, x1: x1))
        }
        return out
    }

    private static func appendRow(
        _ screen: Screen, y: Int, text: inout String, map: inout [(Int, Int)]
    ) {
        let row = rowCells(screen, y)
        var x = 0
        while x < row.count {
            let cell = row[x]
            let wide = cell.wide
            if wide != WIDE_TAIL, wide != WIDE_HEAD {
                if (cell.content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME {
                    var n: UInt16 = 0
                    if let cps = jt_grapheme_get(screen.implPtr, cell.contentPayload, &n) {
                        var i = 0
                        while i < Int(n) {
                            appendScalar(cps[i], y: y, x: x, text: &text, map: &map)
                            i += 1
                        }
                    }
                } else {
                    let p = cell.contentPayload
                    if p != 0 {
                        appendScalar(p, y: y, x: x, text: &text, map: &map)
                    }
                }
            }
            x += 1
        }
    }

    private static func appendScalar(
        _ p: UInt32, y: Int, x: Int, text: inout String, map: inout [(Int, Int)]
    ) {
        guard let u = UnicodeScalar(p) else { return }
        let s = String(Character(u))
        text.append(contentsOf: s)
        let n = s.utf16.count
        var i = 0
        while i < n {
            map.append((y, x))
            i += 1
        }
    }

    private static func covers(x: Int, y: Int, range: NSRange, map: [(Int, Int)]) -> Bool {
        let end = range.location + range.length
        var i = range.location
        while i < end, i < map.count {
            if map[i].0 == y, map[i].1 == x { return true }
            i += 1
        }
        return false
    }

    private static func spans(range: NSRange, map: [(Int, Int)]) -> [Span] {
        var out: [Span] = []
        let end = min(range.location + range.length, map.count)
        var i = range.location
        while i < end {
            let y = map[i].0
            var x0 = map[i].1
            var x1 = x0
            i += 1
            while i < end, map[i].0 == y {
                let x = map[i].1
                if x < x0 { x0 = x }
                if x > x1 { x1 = x }
                i += 1
            }
            out.append(Span(y: y, x0: x0, x1: x1))
        }
        return out
    }
}
