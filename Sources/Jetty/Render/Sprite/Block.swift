import Foundation

/// Block Elements U+2580…U+259F (Ghostty `draw/block.zig`).
enum BlockSprites {
    static func covers(_ cp: UInt32) -> Bool {
        (0x2580...0x259F).contains(cp)
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        switch cp {
        case 0x2580: // ▀ upper half
            block(metrics, canvas, .upper, 1, SpriteCommon.half)
        case 0x2581:
            block(metrics, canvas, .lower, 1, SpriteCommon.oneEighth)
        case 0x2582:
            block(metrics, canvas, .lower, 1, SpriteCommon.oneQuarter)
        case 0x2583:
            block(metrics, canvas, .lower, 1, SpriteCommon.threeEighths)
        case 0x2584:
            block(metrics, canvas, .lower, 1, SpriteCommon.half)
        case 0x2585:
            block(metrics, canvas, .lower, 1, SpriteCommon.fiveEighths)
        case 0x2586:
            block(metrics, canvas, .lower, 1, SpriteCommon.threeQuarters)
        case 0x2587:
            block(metrics, canvas, .lower, 1, SpriteCommon.sevenEighths)
        case 0x2588:
            fullBlock(metrics, canvas, .on)
        case 0x2589:
            block(metrics, canvas, .left, SpriteCommon.sevenEighths, 1)
        case 0x258A:
            block(metrics, canvas, .left, SpriteCommon.threeQuarters, 1)
        case 0x258B:
            block(metrics, canvas, .left, SpriteCommon.fiveEighths, 1)
        case 0x258C:
            block(metrics, canvas, .left, SpriteCommon.half, 1)
        case 0x258D:
            block(metrics, canvas, .left, SpriteCommon.threeEighths, 1)
        case 0x258E:
            block(metrics, canvas, .left, SpriteCommon.oneQuarter, 1)
        case 0x258F:
            block(metrics, canvas, .left, SpriteCommon.oneEighth, 1)
        case 0x2590:
            block(metrics, canvas, .right, SpriteCommon.half, 1)
        case 0x2591:
            fullBlock(metrics, canvas, .light)
        case 0x2592:
            fullBlock(metrics, canvas, .medium)
        case 0x2593:
            fullBlock(metrics, canvas, .dark)
        case 0x2594:
            block(metrics, canvas, .upper, 1, SpriteCommon.oneEighth)
        case 0x2595:
            block(metrics, canvas, .right, SpriteCommon.oneEighth, 1)
        case 0x2596:
            quadrant(metrics, canvas, SpriteCommon.Quads(bl: true))
        case 0x2597:
            quadrant(metrics, canvas, SpriteCommon.Quads(br: true))
        case 0x2598:
            quadrant(metrics, canvas, SpriteCommon.Quads(tl: true))
        case 0x2599:
            quadrant(metrics, canvas, SpriteCommon.Quads(tl: true, bl: true, br: true))
        case 0x259A:
            quadrant(metrics, canvas, SpriteCommon.Quads(tl: true, br: true))
        case 0x259B:
            quadrant(metrics, canvas, SpriteCommon.Quads(tl: true, tr: true, bl: true))
        case 0x259C:
            quadrant(metrics, canvas, SpriteCommon.Quads(tl: true, tr: true, br: true))
        case 0x259D:
            quadrant(metrics, canvas, SpriteCommon.Quads(tr: true))
        case 0x259E:
            quadrant(metrics, canvas, SpriteCommon.Quads(tr: true, bl: true))
        case 0x259F:
            quadrant(metrics, canvas, SpriteCommon.Quads(tr: true, bl: true, br: true))
        default:
            break
        }
    }

    private static func block(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ alignment: SpriteCommon.Alignment,
        _ widthFrac: Double,
        _ heightFrac: Double,
        shade: SpriteCommon.Shade = .on
    ) {
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let w = max(1, Int((fw * widthFrac).rounded()))
        let h = max(1, Int((fh * heightFrac).rounded()))
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
        canvas.fillRect(x: x, y: y, w: w, h: h, value: shade.rawValue)
    }

    private static func fullBlock(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ shade: SpriteCommon.Shade
    ) {
        canvas.box(
            x0: 0, y0: 0,
            x1: metrics.cellWidth, y1: metrics.cellHeight,
            value: shade.rawValue
        )
    }

    private static func quadrant(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ q: SpriteCommon.Quads
    ) {
        if q.tl { SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .zero, y1: .half) }
        if q.tr { SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .zero, y1: .half) }
        if q.bl { SpriteCommon.fill(metrics, canvas, x0: .zero, x1: .half, y0: .half, y1: .full) }
        if q.br { SpriteCommon.fill(metrics, canvas, x0: .half, x1: .full, y0: .half, y1: .full) }
    }
}
