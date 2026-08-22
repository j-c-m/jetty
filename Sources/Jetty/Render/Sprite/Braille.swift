import Foundation

/// Braille Patterns U+2800…U+28FF (Ghostty `braille.zig`), as a sprite drawer.
enum BrailleSprites {
    static let codepointRange: ClosedRange<UInt32> = 0x2800...0x28FF

    static func covers(_ cp: UInt32) -> Bool {
        codepointRange.contains(cp)
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        _ = metrics
        guard codepointRange.contains(cp) else { return }
        let width = canvas.width
        let height = canvas.height

        var w = min(width / 4, height / 8)
        var xSpacing = width / 4
        var ySpacing = height / 8
        var xMargin = xSpacing / 2
        var yMargin = ySpacing / 2

        var xLeft = width - 2 * xMargin - xSpacing - 2 * w
        var yLeft = height - 2 * yMargin - 3 * ySpacing - 4 * w

        if xLeft >= 2, yLeft >= 4, w == 0 {
            w += 1
            xLeft -= 2
            yLeft -= 4
        }
        if xLeft >= 2, xMargin == 0 {
            xMargin = 1
            xLeft -= 2
        }
        if yLeft >= 2, yMargin == 0 {
            yMargin = 1
            yLeft -= 2
        }
        if xLeft >= 1 {
            xSpacing += 1
            xLeft -= 1
        }
        if yLeft >= 3 {
            ySpacing += 1
            yLeft -= 3
        }
        if xLeft >= 2 {
            xMargin += 1
            xLeft -= 2
        }
        if yLeft >= 2 {
            yMargin += 1
            yLeft -= 2
        }
        if xLeft >= 2, yLeft >= 4 {
            w += 1
        }

        w = max(1, w)

        let xs = [xMargin, xMargin + w + xSpacing]
        var ys = [0, 0, 0, 0]
        ys[0] = yMargin
        ys[1] = ys[0] + w + ySpacing
        ys[2] = ys[1] + w + ySpacing
        ys[3] = ys[2] + w + ySpacing

        let bits = UInt8(truncatingIfNeeded: cp & 0xFF)
        let dots: [(col: Int, row: Int, bit: UInt8)] = [
            (0, 0, 1 << 0),
            (0, 1, 1 << 1),
            (0, 2, 1 << 2),
            (1, 0, 1 << 3),
            (1, 1, 1 << 4),
            (1, 2, 1 << 5),
            (0, 3, 1 << 6),
            (1, 3, 1 << 7),
        ]

        for d in dots where bits & d.bit != 0 {
            canvas.box(
                x0: xs[d.col], y0: ys[d.row],
                x1: xs[d.col] + w, y1: ys[d.row] + w,
                value: 255
            )
        }
    }
}
