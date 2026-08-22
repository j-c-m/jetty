import Foundation

/// Powerline + Powerline Extra Symbols | U+E0B0...U+E0BF, U+E0D2, U+E0D4
/// Ghostty `draw/powerline.zig`
enum PowerlineSprites {
    static func covers(_ cp: UInt32) -> Bool {
        switch cp {
        case 0xE0B0...0xE0BF, 0xE0D2, 0xE0D4:
            return true
        default:
            return false
        }
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        let w = metrics.cellWidth
        let h = metrics.cellHeight
        switch cp {
        case 0xE0B0: drawSolidRightArrow(canvas: canvas, width: w, height: h)
        case 0xE0B1: drawOutlineRightArrow(canvas: canvas, width: w, height: h, metrics: metrics)
        case 0xE0B2: drawSolidLeftArrow(canvas: canvas, width: w, height: h)
        case 0xE0B3:
            drawOutlineRightArrow(canvas: canvas, width: w, height: h, metrics: metrics)
            canvas.flipHorizontal()
        case 0xE0B4: drawHalfBubble(canvas: canvas, width: w, height: h)
        case 0xE0B5: drawHalfBubbleOutline(canvas: canvas, width: w, height: h, metrics: metrics)
        case 0xE0B6:
            drawHalfBubble(canvas: canvas, width: w, height: h)
            canvas.flipHorizontal()
        case 0xE0B7:
            drawHalfBubbleOutline(canvas: canvas, width: w, height: h, metrics: metrics)
            canvas.flipHorizontal()
        case 0xE0B8:
            canvas.fillTriangle(
                p0: .init(x: 0, y: 0),
                p1: .init(x: Double(w), y: Double(h)),
                p2: .init(x: 0, y: Double(h))
            )
        case 0xE0B9: BoxSprites.lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        case 0xE0BA:
            canvas.fillTriangle(
                p0: .init(x: Double(w), y: 0),
                p1: .init(x: Double(w), y: Double(h)),
                p2: .init(x: 0, y: Double(h))
            )
        case 0xE0BB: BoxSprites.lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        case 0xE0BC:
            canvas.fillTriangle(
                p0: .init(x: 0, y: 0),
                p1: .init(x: Double(w), y: 0),
                p2: .init(x: 0, y: Double(h))
            )
        case 0xE0BD: BoxSprites.lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        case 0xE0BE:
            canvas.fillTriangle(
                p0: .init(x: 0, y: 0),
                p1: .init(x: Double(w), y: 0),
                p2: .init(x: Double(w), y: Double(h))
            )
        case 0xE0BF: BoxSprites.lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        case 0xE0D2: drawFlame(canvas: canvas, width: w, height: h, metrics: metrics)
        case 0xE0D4:
            drawFlame(canvas: canvas, width: w, height: h, metrics: metrics)
            canvas.flipHorizontal()
        default: break
        }
    }

    // 
    private static func drawSolidRightArrow(canvas: SpriteCanvas, width: Int, height: Int) {
        let fw = Double(width)
        let fh = Double(height)
        canvas.fillTriangle(
            p0: .init(x: 0, y: 0),
            p1: .init(x: fw, y: fh / 2),
            p2: .init(x: 0, y: fh)
        )
    }

    // 
    private static func drawSolidLeftArrow(canvas: SpriteCanvas, width: Int, height: Int) {
        let fw = Double(width)
        let fh = Double(height)
        canvas.fillTriangle(
            p0: .init(x: fw, y: 0),
            p1: .init(x: 0, y: fh / 2),
            p2: .init(x: fw, y: fh)
        )
    }

    // 
    private static func drawOutlineRightArrow(
        canvas: SpriteCanvas, width: Int, height: Int, metrics: SpriteMetrics
    ) {
        let fw = Double(width)
        let fh = Double(height)
        let path = SpriteCanvas.Path()
        path.moveTo(0, 0)
        path.lineTo(fw, fh / 2)
        path.lineTo(0, fh)
        let thick = Double(SpriteCommon.Thickness.light.height(base: metrics.boxThickness))
        canvas.strokePath(path, thickness: thick, value: 255)
    }

    //  circular right half-bubble
    private static func drawHalfBubble(canvas: SpriteCanvas, width: Int, height: Int) {
        let fw = Double(width)
        let fh = Double(height)
        let c = (2.0.squareRoot() - 1.0) * 4.0 / 3.0
        let radius = min(fw, fh / 2)

        let path = SpriteCanvas.Path()
        path.moveTo(0, 0)
        path.curveTo(
            radius * c, 0,
            radius, radius - radius * c,
            radius, radius
        )
        path.lineTo(radius, fh - radius)
        path.curveTo(
            radius, fh - radius + radius * c,
            radius * c, fh,
            0, fh
        )
        path.close()
        canvas.fillPath(path, value: 255)
    }

    // 
    private static func drawHalfBubbleOutline(
        canvas: SpriteCanvas, width: Int, height: Int, metrics: SpriteMetrics
    ) {
        let fw = Double(width)
        let fh = Double(height)
        let c = (2.0.squareRoot() - 1.0) * 4.0 / 3.0
        let radius = min(fw, fh / 2)

        let path = SpriteCanvas.Path()
        path.moveTo(0, 0)
        path.lineTo(1, 0)
        path.curveTo(
            radius * c, 0,
            radius, radius - radius * c,
            radius, radius
        )
        path.lineTo(radius, fh - radius)
        path.curveTo(
            radius, fh - radius + radius * c,
            radius * c, fh,
            1, fh
        )
        path.lineTo(0, fh)
        canvas.innerStrokePath(path, thickness: Double(metrics.boxThickness), value: 255)
    }

    // 
    private static func drawFlame(
        canvas: SpriteCanvas, width: Int, height: Int, metrics: SpriteMetrics
    ) {
        let fw = Double(width)
        let fh = Double(height)
        let ft = Double(metrics.boxThickness)

        let top = SpriteCanvas.Path()
        top.moveTo(0, 0)
        top.lineTo(fw, 0)
        top.lineTo(fw / 2, fh / 2 - ft / 2)
        top.lineTo(0, fh / 2 - ft / 2)
        top.close()
        canvas.fillPath(top, value: 255)

        let bottom = SpriteCanvas.Path()
        bottom.moveTo(0, fh)
        bottom.lineTo(fw, fh)
        bottom.lineTo(fw / 2, fh / 2 + ft / 2)
        bottom.lineTo(0, fh / 2 + ft / 2)
        bottom.close()
        canvas.fillPath(bottom, value: 255)
    }
}
