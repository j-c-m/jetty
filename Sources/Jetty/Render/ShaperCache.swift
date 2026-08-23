import CoreGraphics
import CoreText
import Foundation

struct ShapedCell: Sendable {
    var x: UInt16
    var xOffset: Int16
    var yOffset: Int16
    var glyph: CGGlyph
}

final class ShaperCache {
    private let bucketCount = 512
    private let bucketSize = 8
    private var buckets: [[Bucket]]
    private var featured: [FeaturedKey: CTFont] = [:]

    private struct Bucket {
        var key: UInt64
        var value: [ShapedCell]
    }

    private struct FeaturedKey: Hashable {
        var id: ObjectIdentifier
        var calt: Bool
        var liga: Bool
    }

    static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    init() {
        let cap = 8
        var b: [[Bucket]] = []
        b.reserveCapacity(512)
        for _ in 0..<512 {
            var row: [Bucket] = []
            row.reserveCapacity(cap)
            b.append(row)
        }
        buckets = b
    }

    func clear() {
        for i in buckets.indices {
            buckets[i].removeAll(keepingCapacity: true)
        }
        featured.removeAll(keepingCapacity: true)
    }

    func featuredFont(_ base: CTFont, feature: String) -> CTFont {
        var liga = true
        var calt = true
        for raw in feature.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t == "-calt" || t == "calt=0" { calt = false }
            if t == "+calt" || t == "calt" { calt = true }
            if t == "-liga" || t == "liga=0" { liga = false }
            if t == "+liga" || t == "liga" { liga = true }
        }
        let key = FeaturedKey(id: ObjectIdentifier(base as AnyObject), calt: calt, liga: liga)
        if let hit = featured[key] { return hit }
        let created = Self.makeFeatured(base, liga: liga, calt: calt)
        featured[key] = created
        return created
    }

    func shape(text: String, font: CTFont, fontPx: Int) -> [ShapedCell] {
        guard !text.isEmpty else { return [] }
        var digest = Self.fnvOffset
        digest ^= UInt64(fontPx)
        digest &*= Self.fnvPrime
        digest ^= UInt64(text.utf8.count)
        digest &*= Self.fnvPrime
        for b in text.utf8 {
            digest ^= UInt64(b)
            digest &*= Self.fnvPrime
        }
        digest ^= UInt64(bitPattern: Int64(ObjectIdentifier(font as AnyObject).hashValue))
        digest &*= Self.fnvPrime
        let i = Int(digest & UInt64(bucketCount - 1))
        if let j = buckets[i].firstIndex(where: { $0.key == digest }) {
            if j + 1 != buckets[i].count {
                let e = buckets[i].remove(at: j)
                buckets[i].append(e)
                return e.value
            }
            return buckets[i][j].value
        }
        let shaped = shapeUncached(text: text, font: font)
        if buckets[i].count == bucketSize { buckets[i].removeFirst() }
        buckets[i].append(Bucket(key: digest, value: shaped))
        return shaped
    }

    /// One cmap glyph per Swift `Character` (terminal cell), not per UTF-16 unit.
    static func cmapGlyphs(text: String, font: CTFont) -> [CGGlyph] {
        let units = Array(text.utf16)
        var cmap = [CGGlyph](repeating: 0, count: units.count)
        if !units.isEmpty {
            _ = units.withUnsafeBufferPointer { src in
                cmap.withUnsafeMutableBufferPointer { dst in
                    CTFontGetGlyphsForCharacters(
                        font, src.baseAddress!, dst.baseAddress!, units.count
                    )
                }
            }
        }
        var starts: [Int] = [0]
        var u = 0
        for ch in text {
            u += ch.utf16.count
            starts.append(u)
        }
        var out = [CGGlyph](repeating: 0, count: max(0, starts.count - 1))
        for i in out.indices {
            let gi = starts[i]
            if gi < cmap.count { out[i] = cmap[gi] }
        }
        return out
    }

    /// JetBrains `calt` is spacer + liga glyph at `xOffset≈0`. Detect cmap mismatch.
    static func ligatedMask(_ shaped: [ShapedCell], cells: Int, cmap: [CGGlyph]) -> [Bool] {
        var lig = [Bool](repeating: false, count: cells)
        if shaped.isEmpty || cells <= 0 { return lig }
        var seen = Set<UInt16>()
        var covered = [Bool](repeating: false, count: cells)
        for s in shaped {
            let i = Int(s.x)
            if i < 0 || i >= cells { continue }
            covered[i] = true
            if abs(s.xOffset) >= 2 || s.yOffset != 0 { lig[i] = true }
            if i < cmap.count, s.glyph != cmap[i] { lig[i] = true }
            if !seen.insert(s.x).inserted { lig[i] = true }
        }
        for i in 0..<cells where !covered[i] {
            lig[i] = true
        }
        return lig
    }

    static func isLigature(_ shaped: [ShapedCell], text: String, font: CTFont) -> Bool {
        if shaped.isEmpty || text.isEmpty { return false }
        let cmap = cmapGlyphs(text: text, font: font)
        return ligatedMask(shaped, cells: cmap.count, cmap: cmap).contains(true)
    }

    private func shapeUncached(text: String, font: CTFont) -> [ShapedCell] {
        var utf16Starts: [Int] = [0]
        utf16Starts.reserveCapacity(text.count + 1)
        var u = 0
        for ch in text {
            u += ch.utf16.count
            utf16Starts.append(u)
        }
        let cellCount = utf16Starts.count - 1
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        guard let attr = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attrs as CFDictionary
        ) else { return [] }
        let tsOpts: [CFString: Any] = [
            kCTTypesetterOptionForcedEmbeddingLevel: NSNumber(value: 0),
        ]
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attr, tsOpts as CFDictionary
        ) else { return [] }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }

        var runOffsetX: CGFloat = 0
        var runOffsetCluster = 0
        var cellOffsetX: CGFloat = 0
        var cellOffsetCluster = 0
        var out: [ShapedCell] = []
        out.reserveCapacity(cellCount)

        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetAdvances(run, range, &advances)
            CTRunGetPositions(run, range, &positions)
            CTRunGetStringIndices(run, range, &indices)
            for i in 0..<count {
                let utf16Index = Int(indices[i])
                let cluster = Self.cellIndex(utf16: utf16Index, starts: utf16Starts)
                guard cluster >= 0, cluster < cellCount else {
                    runOffsetX += advances[i].width
                    continue
                }
                if cellOffsetCluster != cluster {
                    let isAfter = cluster <= runOffsetCluster
                    let isFirst = cluster < utf16Starts.count - 1 && utf16Index == utf16Starts[cluster]
                    if isFirst && !isAfter {
                        cellOffsetCluster = cluster
                        cellOffsetX = runOffsetX
                    }
                }
                out.append(ShapedCell(
                    x: UInt16(cluster),
                    xOffset: Int16((positions[i].x - cellOffsetX).rounded()),
                    yOffset: Int16(positions[i].y.rounded()),
                    glyph: glyphs[i]
                ))
                runOffsetX += advances[i].width
                runOffsetCluster = max(runOffsetCluster, cluster)
            }
        }
        return out
    }

    private static func cellIndex(utf16: Int, starts: [Int]) -> Int {
        var lo = 0
        var hi = starts.count - 2
        var ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= utf16 {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    private static func makeFeatured(_ base: CTFont, liga: Bool, calt: Bool) -> CTFont {
        let features: [[CFString: Any]] = [
            [
                kCTFontOpenTypeFeatureTag: "liga" as CFString,
                kCTFontOpenTypeFeatureValue: NSNumber(value: liga ? 1 : 0),
            ],
            [
                kCTFontOpenTypeFeatureTag: "calt" as CFString,
                kCTFontOpenTypeFeatureValue: NSNumber(value: calt ? 1 : 0),
            ],
        ]
        let desc = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, 0, nil, desc)
    }
}
