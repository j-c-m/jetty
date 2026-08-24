import CVt
import Foundation

enum ScrollSearch {
    struct Span: Equatable {
        var docRow: Int
        var x0: Int
        var x1: Int
    }

    struct Hit: Equatable {
        var docRow: Int
        var spans: [Span]
    }

    static func hits(query: String, screen: Screen, liveRows: Int, lock: NSLock? = nil) -> [Hit] {
        let needle = foldQuery(query)
        if needle.isEmpty { return [] }
        lock?.lock()
        let sb0 = screen.viewportHistoryCount
        let cols = screen.cols
        lock?.unlock()
        let total = sb0 + liveRows
        var out: [Hit] = []
        var doc = 0
        var cells = ContiguousArray<Cell>()
        var wrap = [UInt8]()
        var graphs: [UInt32: [UInt32]] = [:]
        while doc < total {
            var take = min(256, total - doc)
            lock?.lock()
            let sb = screen.viewportHistoryCount
            while take < total - doc {
                let last = doc + take - 1
                if !wrappedAt(screen, last, sb: sb, liveRows: liveRows) { break }
                take += 1
                if take >= 512 { break }
            }
            let n = take
            if cells.count < n * cols {
                cells = ContiguousArray(repeating: .empty, count: n * cols)
            }
            if wrap.count < n { wrap = [UInt8](repeating: 0, count: n) }
            graphs.removeAll(keepingCapacity: true)
            var blank = Cell.empty
            blank.content = content_scalar(0x20, WIDE_NARROW)
            cells.withUnsafeMutableBufferPointer { buf in
                guard let p = buf.baseAddress else { return }
                var r = 0
                while r < n {
                    screen.blitDocumentRow(
                        doc + r, to: p + r * cols, destCols: cols, liveRows: liveRows, blank: blank
                    )
                    wrap[r] = wrappedAt(screen, doc + r, sb: sb, liveRows: liveRows) ? 1 : 0
                    var x = 0
                    while x < cols {
                        let c = p[r * cols + x]
                        if (c.content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME {
                            let id = c.contentPayload
                            if graphs[id] == nil {
                                var gn: UInt16 = 0
                                if let cps = jt_grapheme_get(screen.implPtr, id, &gn) {
                                    var arr: [UInt32] = []
                                    var gi = 0
                                    while gi < Int(gn) {
                                        arr.append(cps[gi])
                                        gi += 1
                                    }
                                    graphs[id] = arr
                                }
                            }
                        }
                        x += 1
                    }
                    r += 1
                }
            }
            lock?.unlock()
            out.append(contentsOf: matchChunk(
                needle: needle,
                cells: cells,
                wrap: wrap,
                n: n,
                cols: cols,
                docOrigin: doc,
                graphs: graphs
            ))
            doc += n
        }
        out.reverse()
        return out
    }

    private static func wrappedAt(_ screen: Screen, _ doc: Int, sb: Int, liveRows: Int) -> Bool {
        if doc < sb { return screen.isHistoryWrapped(doc) }
        let y = doc - sb
        guard y >= 0, y < liveRows else { return false }
        return screen.isWrapped(y)
    }

    private static func foldQuery(_ query: String) -> [UInt32] {
        var out: [UInt32] = []
        for sc in query.unicodeScalars {
            out.append(contentsOf: foldCp(sc.value))
        }
        return out
    }

    private static func foldCp(_ p: UInt32) -> [UInt32] {
        if p == 0 { return [] }
        if p < 128 {
            let f = (p >= 65 && p <= 90) ? p &+ 32 : p
            return [f]
        }
        guard let u = UnicodeScalar(p) else { return [p] }
        var out: [UInt32] = []
        for s in String(Character(u)).lowercased().unicodeScalars {
            out.append(s.value)
        }
        return out
    }

    private static func matchChunk(
        needle: [UInt32],
        cells: ContiguousArray<Cell>,
        wrap: [UInt8],
        n: Int,
        cols: Int,
        docOrigin: Int,
        graphs: [UInt32: [UInt32]]
    ) -> [Hit] {
        var out: [Hit] = []
        var row = 0
        while row < n {
            var folded: [UInt32] = []
            var map: [(Int, Int)] = []
            var r = row
            while r < n {
                let base = r * cols
                var x = 0
                while x < cols {
                    let c = cells[base + x]
                    let w = c.wide
                    if w != WIDE_TAIL, w != WIDE_HEAD {
                        let cps: [UInt32]
                        if (c.content & CONTENT_KIND_MASK) == CONTENT_GRAPHEME {
                            cps = graphs[c.contentPayload] ?? []
                        } else {
                            let p = c.contentPayload
                            cps = p == 0 ? [] : [p]
                        }
                        for cp in cps {
                            for f in foldCp(cp) {
                                folded.append(f)
                                map.append((docOrigin + r, x))
                            }
                        }
                    }
                    x += 1
                }
                r += 1
                if wrap[r - 1] == 0 { break }
            }
            out.append(contentsOf: match(needle, folded: folded, map: map))
            row = max(r, row + 1)
        }
        return out
    }

    private static func match(
        _ needle: [UInt32],
        folded: [UInt32],
        map: [(Int, Int)]
    ) -> [Hit] {
        if needle.isEmpty || folded.count < needle.count { return [] }
        var out: [Hit] = []
        var i = 0
        let last = folded.count - needle.count
        while i <= last {
            var ok = true
            var k = 0
            while k < needle.count {
                if folded[i + k] != needle[k] {
                    ok = false
                    break
                }
                k += 1
            }
            if ok {
                var spans: [Span] = []
                var p = i
                let end = i + needle.count
                while p < end {
                    let row = map[p].0
                    var x0 = map[p].1
                    var x1 = x0
                    p += 1
                    while p < end, map[p].0 == row {
                        let x = map[p].1
                        if x < x0 { x0 = x }
                        if x > x1 { x1 = x }
                        p += 1
                    }
                    spans.append(Span(docRow: row, x0: x0, x1: x1))
                }
                if let lastSpan = spans.last {
                    out.append(Hit(docRow: lastSpan.docRow, spans: spans))
                }
                i += needle.count
            } else {
                i += 1
            }
        }
        return out
    }
}
