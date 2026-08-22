import Foundation

// MARK: - Shared sprite drawing helpers (Ghostty draw/common.zig)

enum SpriteCommon {
    static let oneEighth: Double = 0.125
    static let oneQuarter: Double = 0.25
    static let oneThird: Double = 1.0 / 3.0
    static let threeEighths: Double = 0.375
    static let half: Double = 0.5
    static let fiveEighths: Double = 0.625
    static let twoThirds: Double = 2.0 / 3.0
    static let threeQuarters: Double = 0.75
    static let sevenEighths: Double = 0.875

    /// Line stroke thickness relative to `boxThickness`.
    enum Thickness {
        case superLight
        case light
        case heavy

        func height(base: Int) -> Int {
            switch self {
            case .superLight: return max(base / 2, 1)
            case .light: return base
            case .heavy: return base * 2
            }
        }
    }

    /// Coverage shades used by block elements.
    enum Shade: UInt8 {
        case off = 0x00
        case light = 0x40
        case medium = 0x80
        case dark = 0xc0
        case on = 0xff
    }

    struct Quads {
        var tl: Bool = false
        var tr: Bool = false
        var bl: Bool = false
        var br: Bool = false
    }

    enum Corner {
        case tl, tr, bl, br
    }

    enum Edge {
        case top, left, bottom, right
    }

    struct Alignment {
        enum Horizontal { case left, right, center }
        enum Vertical { case top, bottom, middle }

        var horizontal: Horizontal
        var vertical: Vertical

        static let upper = Alignment(horizontal: .center, vertical: .top)
        static let lower = Alignment(horizontal: .center, vertical: .bottom)
        static let left = Alignment(horizontal: .left, vertical: .middle)
        static let right = Alignment(horizontal: .right, vertical: .middle)
        static let center = Alignment(horizontal: .center, vertical: .middle)
        static let upperLeft = Alignment(horizontal: .left, vertical: .top)
        static let upperRight = Alignment(horizontal: .right, vertical: .top)
        static let lowerLeft = Alignment(horizontal: .left, vertical: .bottom)
        static let lowerRight = Alignment(horizontal: .right, vertical: .bottom)
        static let upperCenter = upper
        static let lowerCenter = lower
        static let middleLeft = left
        static let middleRight = right
        static let middleCenter = center
        static let top = upper
        static let bottom = lower
        static let topLeft = upperLeft
        static let topRight = upperRight
        static let bottomLeft = lowerLeft
        static let bottomRight = lowerRight
    }

    /// Fraction across a cell edge (Ghostty `Fraction`).
    enum Fraction {
        case start, left, top, zero
        case eighth, oneEighth, twoEighths, threeEighths, fourEighths
        case fiveEighths, sixEighths, sevenEighths
        case quarter, oneQuarter, twoQuarters, threeQuarters
        case third, oneThird, twoThirds
        case half, oneHalf, center, middle
        case end, right, bottom, one, full

        static let eighths: [Fraction] = [
            .zero, .oneEighth, .twoEighths, .threeEighths, .fourEighths,
            .fiveEighths, .sixEighths, .sevenEighths, .one,
        ]
        static let quarters: [Fraction] = [
            .zero, .oneQuarter, .twoQuarters, .threeQuarters, .one,
        ]
        static let thirds: [Fraction] = [.zero, .oneThird, .twoThirds, .one]
        static let halves: [Fraction] = [.zero, .oneHalf, .one]

        func fraction() -> Double {
            switch self {
            case .start, .left, .top, .zero: return 0.0
            case .eighth, .oneEighth: return 0.125
            case .quarter, .oneQuarter, .twoEighths: return 0.25
            case .third, .oneThird: return 1.0 / 3.0
            case .threeEighths: return 0.375
            case .half, .oneHalf, .twoQuarters, .fourEighths, .center, .middle: return 0.5
            case .fiveEighths: return 0.625
            case .twoThirds: return 2.0 / 3.0
            case .threeQuarters, .sixEighths: return 0.75
            case .sevenEighths: return 0.875
            case .end, .right, .bottom, .one, .full: return 1.0
            }
        }

        /// Min edge (left/top): Ghostty `s - round((1 - f) * s)`.
        func min(_ size: Int) -> Int {
            let s = Double(size)
            return Int(s - ((1.0 - fraction()) * s).rounded())
        }

        /// Max edge (right/bottom): Ghostty `round(f * s)`.
        func max(_ size: Int) -> Int {
            let s = Double(size)
            return Int((fraction() * s).rounded())
        }

        func float(_ size: Int) -> Double {
            fraction() * Double(size)
        }
    }

    /// Saturating subtract for non-negative sizes (Zig `a -| b`).
    static func satSub(_ a: Int, _ b: Int) -> Int {
        max(0, a - b)
    }

    /// Fill a section of the cell between fraction lines.
    static func fill(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        x0: Fraction, x1: Fraction,
        y0: Fraction, y1: Fraction
    ) {
        canvas.box(
            x0: x0.min(metrics.cellWidth),
            y0: y0.min(metrics.cellHeight),
            x1: x1.max(metrics.cellWidth),
            y1: y1.max(metrics.cellHeight),
            value: Shade.on.rawValue
        )
    }

    static func vlineMiddle(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        thickness: Thickness
    ) {
        let thickPx = thickness.height(base: metrics.boxThickness)
        vline(
            canvas,
            y1: 0,
            y2: metrics.cellHeight,
            x: satSub(metrics.cellWidth, thickPx) / 2,
            thicknessPx: thickPx
        )
    }

    static func hlineMiddle(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        thickness: Thickness
    ) {
        let thickPx = thickness.height(base: metrics.boxThickness)
        hline(
            canvas,
            x1: 0,
            x2: metrics.cellWidth,
            y: satSub(metrics.cellHeight, thickPx) / 2,
            thicknessPx: thickPx
        )
    }

    static func vline(
        _ canvas: SpriteCanvas,
        y1: Int,
        y2: Int,
        x: Int,
        thicknessPx: Int
    ) {
        canvas.box(x0: x, y0: y1, x1: x + thicknessPx, y1: y2, value: 255)
    }

    static func hline(
        _ canvas: SpriteCanvas,
        x1: Int,
        x2: Int,
        y: Int,
        thicknessPx: Int
    ) {
        canvas.box(x0: x1, y0: y, x1: x2, y1: y + thicknessPx, value: 255)
    }

    /// Aligned block of fractional cell size (Ghostty `block` / `blockShade`).
    static func blockAligned(
        canvas: SpriteCanvas,
        metrics: SpriteMetrics,
        alignment: Alignment,
        fracW: Double,
        fracH: Double,
        value: UInt8 = 255
    ) {
        let w = Int((Double(metrics.cellWidth) * fracW).rounded())
        let h = Int((Double(metrics.cellHeight) * fracH).rounded())
        let x: Int
        switch alignment.horizontal {
        case .left: x = 0
        case .right: x = metrics.cellWidth - w
        case .center: x = (metrics.cellWidth - w) / 2
        }
        let y: Int
        switch alignment.vertical {
        case .top: y = 0
        case .bottom: y = metrics.cellHeight - h
        case .middle: y = (metrics.cellHeight - h) / 2
        }
        canvas.fillRect(x: x, y: y, w: w, h: h, value: value)
    }

    static func fullBlock(
        canvas: SpriteCanvas,
        metrics: SpriteMetrics,
        value: UInt8 = Shade.on.rawValue
    ) {
        canvas.box(
            x0: 0, y0: 0,
            x1: metrics.cellWidth, y1: metrics.cellHeight,
            value: value
        )
    }

    /// Ghostty `block.block`.
    static func block(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ alignment: Alignment,
        _ width: Double,
        _ height: Double
    ) {
        blockAligned(
            canvas: canvas, metrics: metrics,
            alignment: alignment, fracW: width, fracH: height
        )
    }

    /// Ghostty `block.blockShade`.
    static func blockShade(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ alignment: Alignment,
        _ width: Double,
        _ height: Double,
        _ shade: Shade
    ) {
        blockAligned(
            canvas: canvas, metrics: metrics,
            alignment: alignment, fracW: width, fracH: height,
            value: shade.rawValue
        )
    }

    /// Ghostty `block.fullBlockShade`.
    static func fullBlockShade(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ shade: Shade
    ) {
        fullBlock(canvas: canvas, metrics: metrics, value: shade.rawValue)
    }

    static func quadrant(
        canvas: SpriteCanvas,
        metrics: SpriteMetrics,
        q: Quads
    ) {
        if q.tl { fill(metrics, canvas, x0: .zero, x1: .half, y0: .zero, y1: .half) }
        if q.tr { fill(metrics, canvas, x0: .half, x1: .full, y0: .zero, y1: .half) }
        if q.bl { fill(metrics, canvas, x0: .zero, x1: .half, y0: .half, y1: .full) }
        if q.br { fill(metrics, canvas, x0: .half, x1: .full, y0: .half, y1: .full) }
    }
}
