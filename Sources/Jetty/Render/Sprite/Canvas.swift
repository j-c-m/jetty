import Foundation

/// Alpha8 coverage canvas, top-left origin, +Y down.
/// Matches Ghostty `font.sprite.Canvas` box semantics: `box` fills `[x0,x1) × [y0,y1)`.
final class SpriteCanvas {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height)
    }

    func clear() {
        pixels = [UInt8](repeating: 0, count: width * height)
    }

    func pixel(x: Int, y: Int, value: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = value
    }

    func getPixel(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    func pixelMax(x: Int, y: Int, value: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = y * width + x
        if value > pixels[i] { pixels[i] = value }
    }

    /// Fill half-open box `[x0,x1) × [y0,y1)`.
    func box(x0: Int, y0: Int, x1: Int, y1: Int, value: UInt8 = 255) {
        let xa = max(0, min(x0, x1))
        let xb = min(width, max(x0, x1))
        let ya = max(0, min(y0, y1))
        let yb = min(height, max(y0, y1))
        guard xa < xb, ya < yb else { return }
        for y in ya..<yb {
            let row = y * width
            for x in xa..<xb {
                pixels[row + x] = value
            }
        }
    }

    func fillRect(x: Int, y: Int, w: Int, h: Int, value: UInt8 = 255) {
        guard w > 0, h > 0 else { return }
        box(x0: x, y0: y, x1: x + w, y1: y + h, value: value)
    }

    /// Horizontal strip: left edge at `x0`, right at `x1`, top at `y`.
    func hline(y: Int, x0: Int, x1: Int, thickness: Int, value: UInt8 = 255) {
        box(x0: x0, y0: y, x1: x1, y1: y + thickness, value: value)
    }

    /// Vertical strip: top at `y0`, bottom at `y1`, left at `x`.
    func vline(x: Int, y0: Int, y1: Int, thickness: Int, value: UInt8 = 255) {
        box(x0: x, y0: y0, x1: x + thickness, y1: y1, value: value)
    }

    func invert() {
        for i in pixels.indices {
            pixels[i] = 255 &- pixels[i]
        }
    }

    // MARK: - Points / paths

    struct Point {
        var x: Double
        var y: Double
        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    final class Path {
        private(set) var points: [Point] = []
        private var closed = false

        func moveTo(_ x: Double, _ y: Double) {
            points = [Point(x: x, y: y)]
            closed = false
        }

        func lineTo(_ x: Double, _ y: Double) {
            points.append(Point(x: x, y: y))
        }

        /// Append a cubic Bézier from the current point to `(x,y)`.
        func curveTo(
            _ cp1x: Double, _ cp1y: Double,
            _ cp2x: Double, _ cp2y: Double,
            _ x: Double, _ y: Double,
            segments: Int = 24
        ) {
            let p0 = points.last ?? Point(x: cp1x, y: cp1y)
            let segs = max(4, segments)
            for s in 1...segs {
                let t = Double(s) / Double(segs)
                let u = 1 - t
                let px = u * u * u * p0.x
                    + 3 * u * u * t * cp1x
                    + 3 * u * t * t * cp2x
                    + t * t * t * x
                let py = u * u * u * p0.y
                    + 3 * u * u * t * cp1y
                    + 3 * u * t * t * cp2y
                    + t * t * t * y
                points.append(Point(x: px, y: py))
            }
        }

        func close() {
            closed = true
        }

        var isClosed: Bool { closed }
    }

    func flipHorizontal() {
        for y in 0..<height {
            let row = y * width
            var lo = 0
            var hi = width - 1
            while lo < hi {
                pixels.swapAt(row + lo, row + hi)
                lo += 1
                hi -= 1
            }
        }
    }

    func flipVertical() {
        for y in 0..<(height / 2) {
            let a = y * width
            let b = (height - 1 - y) * width
            for x in 0..<width {
                pixels.swapAt(a + x, b + x)
            }
        }
    }

    // MARK: - Vector raster

    func strokeLine(
        x0: Double, y0: Double,
        x1: Double, y1: Double,
        thickness: Double,
        value: UInt8 = 255
    ) {
        let dx = x1 - x0
        let dy = y1 - y0
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9, thickness > 0 else { return }

        let hw = thickness * 0.5 + 1.0
        let minX = Int(floor(min(x0, x1) - hw))
        let maxX = Int(ceil(max(x0, x1) + hw))
        let minY = Int(floor(min(y0, y1) - hw))
        let maxY = Int(ceil(max(y0, y1) + hw))
        let invLen2 = 1.0 / (len * len)
        let half = thickness * 0.5

        for py in minY...maxY {
            for px in minX...maxX {
                let cx = Double(px) + 0.5
                let cy = Double(py) + 0.5
                let t = ((cx - x0) * dx + (cy - y0) * dy) * invLen2
                let tc = min(1.0, max(0.0, t))
                let qx = x0 + tc * dx
                let qy = y0 + tc * dy
                let ddx = cx - qx
                let ddy = cy - qy
                let dist = (ddx * ddx + ddy * ddy).squareRoot()
                if dist <= half {
                    pixelMax(x: px, y: py, value: value)
                } else if dist < half + 0.75 {
                    let a = 1.0 - (dist - half) / 0.75
                    let v = UInt8(min(255, max(0, Int((Double(value) * a).rounded()))))
                    pixelMax(x: px, y: py, value: v)
                }
            }
        }
    }

    func strokeLine(_ p0: Point, _ p1: Point, thickness: Double, value: UInt8 = 255) {
        strokeLine(x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y, thickness: thickness, value: value)
    }

    func fillPolygon(_ points: [Point], value: UInt8 = 255) {
        guard points.count >= 3 else { return }
        var minY = Int.max, maxY = Int.min, minX = Int.max, maxX = Int.min
        for p in points {
            minX = min(minX, Int(floor(p.x)))
            maxX = max(maxX, Int(ceil(p.x)))
            minY = min(minY, Int(floor(p.y)))
            maxY = max(maxY, Int(ceil(p.y)))
        }
        minX = max(0, minX)
        maxX = min(width - 1, maxX)
        minY = max(0, minY)
        maxY = min(height - 1, maxY)
        guard minX <= maxX, minY <= maxY else { return }

        let n = points.count
        for py in minY...maxY {
            let y = Double(py) + 0.5
            var crossings: [Double] = []
            for i in 0..<n {
                let a = points[i]
                let b = points[(i + 1) % n]
                if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                    let t = (y - a.y) / (b.y - a.y)
                    crossings.append(a.x + t * (b.x - a.x))
                }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let xStart = Int(ceil(crossings[i]))
                let xEnd = Int(floor(crossings[i + 1]))
                if xStart <= xEnd {
                    let xa = max(minX, xStart)
                    let xb = min(maxX, xEnd)
                    if xa <= xb {
                        let row = py * width
                        for x in xa...xb { pixels[row + x] = value }
                    }
                }
                i += 2
            }
        }
    }

    func fillTriangle(
        p0: Point, p1: Point, p2: Point,
        value: UInt8 = 255
    ) {
        fillPolygon([p0, p1, p2], value: value)
    }

    /// Integer-coordinate triangle (Legacy scaffold / convenience).
    func triangle(
        x0: Int, y0: Int, x1: Int, y1: Int, x2: Int, y2: Int,
        value: UInt8 = 255
    ) {
        fillTriangle(
            p0: Point(x: Double(x0), y: Double(y0)),
            p1: Point(x: Double(x1), y: Double(y1)),
            p2: Point(x: Double(x2), y: Double(y2)),
            value: value
        )
    }

    func fillPath(_ path: Path, value: UInt8 = 255) {
        fillPolygon(path.points, value: value)
    }

    func strokePath(_ path: Path, thickness: Double, value: UInt8 = 255) {
        let pts = path.points
        guard pts.count >= 2 else { return }
        for i in 0..<(pts.count - 1) {
            strokeLine(pts[i], pts[i + 1], thickness: thickness, value: value)
        }
        if path.isClosed, let first = pts.first, let last = pts.last {
            strokeLine(last, first, thickness: thickness, value: value)
        }
    }

    /// Inset stroke of a closed path (approximate Ghostty `innerStrokePath`).
    func innerStrokePath(_ path: Path, thickness: Double, value: UInt8 = 255) {
        // For small cells, full stroke is acceptable; true offset is expensive.
        strokePath(path, thickness: thickness, value: value)
    }

    func strokeCubic(
        x0: Double, y0: Double,
        x1: Double, y1: Double,
        x2: Double, y2: Double,
        x3: Double, y3: Double,
        thickness: Double,
        value: UInt8 = 255,
        segments: Int = 24
    ) {
        var px = x0, py = y0
        let segs = max(4, segments)
        for s in 1...segs {
            let t = Double(s) / Double(segs)
            let u = 1 - t
            let x = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3
            let y = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3
            strokeLine(x0: px, y0: py, x1: x, y1: y, thickness: thickness, value: value)
            px = x
            py = y
        }
    }

    func fillCircle(cx: Double, cy: Double, r: Double, value: UInt8 = 255) {
        guard r > 0 else { return }
        let minX = max(0, Int(floor(cx - r - 1)))
        let maxX = min(width - 1, Int(ceil(cx + r + 1)))
        let minY = max(0, Int(floor(cy - r - 1)))
        let maxY = min(height - 1, Int(ceil(cy + r + 1)))
        let r2 = r * r
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r2 {
                    pixelMax(x: x, y: y, value: value)
                }
            }
        }
    }

    func strokeCircle(cx: Double, cy: Double, r: Double, thickness: Double, value: UInt8 = 255) {
        guard r > 0, thickness > 0 else { return }
        let half = thickness * 0.5
        let outer = r + half
        let inner = max(0, r - half)
        let minX = max(0, Int(floor(cx - outer - 1)))
        let maxX = min(width - 1, Int(ceil(cx + outer + 1)))
        let minY = max(0, Int(floor(cy - outer - 1)))
        let maxY = min(height - 1, Int(ceil(cy + outer + 1)))
        let outer2 = outer * outer
        let inner2 = inner * inner
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                let d2 = dx * dx + dy * dy
                if d2 <= outer2 && d2 >= inner2 {
                    pixelMax(x: x, y: y, value: value)
                }
            }
        }
    }
}
