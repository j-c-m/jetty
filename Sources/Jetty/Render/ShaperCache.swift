import CoreGraphics
import CoreText
import Foundation
import CVt

struct ShapedCell: Sendable {
    var x: UInt16
    var xOffset: Int16
    var yOffset: Int16
    var glyph: CGGlyph
}

struct ShapedRun: Sendable {
    var cells: [ShapedCell]
    var ligated: [Bool]
}

final class ShaperCache {
    private let bucketCount = 512
    private let bucketSize = 8
    private var buckets: [[Bucket]]
    private var featured: [FeaturedKey: CTFont] = [:]
    private(set) var missCount = 0

    private struct Bucket {
        var key: UInt64
        var value: ShapedRun
    }

    private struct FeaturedKey: Hashable {
        var id: ObjectIdentifier
        var calt: Bool
        var liga: Bool
    }

    static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211
    static let space: UnicodeScalar = " "

    static func mix(_ digest: inout UInt64, _ v: UInt64) {
        digest ^= v
        digest &*= fnvPrime
    }

    static func mixCell(_ digest: inout UInt64, cp: UInt32, cluster: Int) {
        mix(&digest, UInt64(cp == 0 ? 32 : cp))
        mix(&digest, UInt64(cluster))
    }

    static func hashCells(row: UnsafePointer<Cell>, start: Int, count: Int) -> UInt64 {
        var digest = fnvOffset
        var i = 0
        while i < count {
            mixCell(&digest, cp: row[start + i].contentPayload, cluster: i)
            i += 1
        }
        mix(&digest, UInt64(count))
        return digest
    }

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
        missCount = 0
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

    /// Lookup by precomputed content hash. Builds the Core Text string on miss only.
    func shape(
        row: UnsafePointer<Cell>,
        start: Int,
        count: Int,
        contentHash: UInt64,
        font: CTFont,
        fontPx: Int,
        bold: Bool,
        italic: Bool,
        feature: String
    ) -> ShapedRun {
        guard count > 0 else { return ShapedRun(cells: [], ligated: []) }

        var digest = contentHash
        Self.mix(&digest, UInt64(fontPx))
        Self.mix(&digest, bold ? 1 : 0)
        Self.mix(&digest, italic ? 1 : 0)
        Self.mix(&digest, UInt64(feature.utf8.count))
        for b in feature.utf8 {
            Self.mix(&digest, UInt64(b))
        }

        let i = Int(digest & UInt64(bucketCount - 1))
        if let j = buckets[i].firstIndex(where: { $0.key == digest }) {
            if j + 1 != buckets[i].count {
                let e = buckets[i].remove(at: j)
                buckets[i].append(e)
                return e.value
            }
            return buckets[i][j].value
        }

        missCount += 1
        let built = Self.textFromCells(row: row, start: start, count: count)
        let shaped = shapeUncached(
            text: built.text,
            cellUTF16Starts: built.starts,
            font: font,
            cellCount: count
        )
        let ligated: [Bool]
        if shaped.isEmpty {
            ligated = [Bool](repeating: false, count: count)
        } else {
            let cmap = Self.cmapGlyphs(text: built.text, starts: built.starts, font: font)
            ligated = Self.ligatedMask(shaped, cells: count, cmap: cmap)
        }
        let run = ShapedRun(cells: shaped, ligated: ligated)
        if buckets[i].count == bucketSize { buckets[i].removeFirst() }
        buckets[i].append(Bucket(key: digest, value: run))
        return run
    }

    /// One cmap glyph per terminal cell (utf16 start), not per Swift `Character`.
    static func cmapGlyphs(text: String, starts: [Int], font: CTFont) -> [CGGlyph] {
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
        let cells = max(0, starts.count - 1)
        var out = [CGGlyph](repeating: 0, count: cells)
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

    static func cellScalar(_ payload: UInt32) -> UnicodeScalar {
        if payload == 0 { return space }
        return UnicodeScalar(payload) ?? space
    }

    static func textFromCells(
        row: UnsafePointer<Cell>,
        start: Int,
        count: Int
    ) -> (text: String, starts: [Int]) {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(count)
        var starts: [Int] = [0]
        starts.reserveCapacity(count + 1)
        var utf16 = 0
        var i = 0
        while i < count {
            let u = cellScalar(row[start + i].contentPayload)
            scalars.append(u)
            utf16 += u.utf16.count
            starts.append(utf16)
            i += 1
        }
        return (String(scalars), starts)
    }

    private func shapeUncached(
        text: String,
        cellUTF16Starts: [Int],
        font: CTFont,
        cellCount: Int
    ) -> [ShapedCell] {
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
                let cluster = Self.cellIndex(utf16: utf16Index, starts: cellUTF16Starts)
                guard cluster >= 0, cluster < cellCount else {
                    runOffsetX += advances[i].width
                    continue
                }
                if cellOffsetCluster != cluster {
                    let isAfter = cluster <= runOffsetCluster
                    let isFirst = cluster < cellUTF16Starts.count - 1
                        && utf16Index == cellUTF16Starts[cluster]
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
