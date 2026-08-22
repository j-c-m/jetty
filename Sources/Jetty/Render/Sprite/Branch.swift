import Foundation

/// Branch Drawing Characters | U+F5D0…U+F60D
/// Faithful port of Ghostty `draw/branch.zig` (Kitty-style git graph glyphs).
enum BranchSprites {
    static let codepointRange: ClosedRange<UInt32> = 0xF5D0...0xF60D

    static func covers(_ cp: UInt32) -> Bool {
        codepointRange.contains(cp)
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        guard covers(cp) else { return }
        switch cp {
        case 0xF5D0: SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
        case 0xF5D1: SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
        case 0xF5D2: fadingLine(metrics, canvas, to: .right)
        case 0xF5D3: fadingLine(metrics, canvas, to: .left)
        case 0xF5D4: fadingLine(metrics, canvas, to: .bottom)
        case 0xF5D5: fadingLine(metrics, canvas, to: .top)
        case 0xF5D6: BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5D7: BoxSprites.arc(metrics, canvas, .bl, .light)
        case 0xF5D8: BoxSprites.arc(metrics, canvas, .tr, .light)
        case 0xF5D9: BoxSprites.arc(metrics, canvas, .tl, .light)
        case 0xF5DA:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tr, .light)
        case 0xF5DB:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5DC:
            BoxSprites.arc(metrics, canvas, .tr, .light)
            BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5DD:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tl, .light)
        case 0xF5DE:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
        case 0xF5DF:
            BoxSprites.arc(metrics, canvas, .tl, .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
        case 0xF5E0:
            BoxSprites.arc(metrics, canvas, .bl, .light)
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
        case 0xF5E1:
            BoxSprites.arc(metrics, canvas, .br, .light)
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
        case 0xF5E2:
            BoxSprites.arc(metrics, canvas, .br, .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
        case 0xF5E3:
            BoxSprites.arc(metrics, canvas, .tl, .light)
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
        case 0xF5E4:
            BoxSprites.arc(metrics, canvas, .tr, .light)
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
        case 0xF5E5:
            BoxSprites.arc(metrics, canvas, .tr, .light)
            BoxSprites.arc(metrics, canvas, .tl, .light)
        case 0xF5E6:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tl, .light)
            BoxSprites.arc(metrics, canvas, .tr, .light)
        case 0xF5E7:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
            BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5E8:
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
            BoxSprites.arc(metrics, canvas, .tl, .light)
        case 0xF5E9:
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tr, .light)
            BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5EA:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tl, .light)
            BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5EB:
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tr, .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
        case 0xF5EC:
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tl, .light)
            BoxSprites.arc(metrics, canvas, .br, .light)
        case 0xF5ED:
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: .light)
            BoxSprites.arc(metrics, canvas, .tr, .light)
            BoxSprites.arc(metrics, canvas, .bl, .light)
        case 0xF5EE: branchNode(metrics, canvas, up: false, right: false, down: false, left: false, filled: true)
        case 0xF5EF: branchNode(metrics, canvas, up: false, right: false, down: false, left: false, filled: false)
        case 0xF5F0: branchNode(metrics, canvas, up: false, right: true, down: false, left: false, filled: true)
        case 0xF5F1: branchNode(metrics, canvas, up: false, right: true, down: false, left: false, filled: false)
        case 0xF5F2: branchNode(metrics, canvas, up: false, right: false, down: false, left: true, filled: true)
        case 0xF5F3: branchNode(metrics, canvas, up: false, right: false, down: false, left: true, filled: false)
        case 0xF5F4: branchNode(metrics, canvas, up: false, right: true, down: false, left: true, filled: true)
        case 0xF5F5: branchNode(metrics, canvas, up: false, right: true, down: false, left: true, filled: false)
        case 0xF5F6: branchNode(metrics, canvas, up: false, right: false, down: true, left: false, filled: true)
        case 0xF5F7: branchNode(metrics, canvas, up: false, right: false, down: true, left: false, filled: false)
        case 0xF5F8: branchNode(metrics, canvas, up: true, right: false, down: false, left: false, filled: true)
        case 0xF5F9: branchNode(metrics, canvas, up: true, right: false, down: false, left: false, filled: false)
        case 0xF5FA: branchNode(metrics, canvas, up: true, right: false, down: true, left: false, filled: true)
        case 0xF5FB: branchNode(metrics, canvas, up: true, right: false, down: true, left: false, filled: false)
        case 0xF5FC: branchNode(metrics, canvas, up: false, right: true, down: true, left: false, filled: true)
        case 0xF5FD: branchNode(metrics, canvas, up: false, right: true, down: true, left: false, filled: false)
        case 0xF5FE: branchNode(metrics, canvas, up: false, right: false, down: true, left: true, filled: true)
        case 0xF5FF: branchNode(metrics, canvas, up: false, right: false, down: true, left: true, filled: false)
        case 0xF600: branchNode(metrics, canvas, up: true, right: true, down: false, left: false, filled: true)
        case 0xF601: branchNode(metrics, canvas, up: true, right: true, down: false, left: false, filled: false)
        case 0xF602: branchNode(metrics, canvas, up: true, right: false, down: false, left: true, filled: true)
        case 0xF603: branchNode(metrics, canvas, up: true, right: false, down: false, left: true, filled: false)
        case 0xF604: branchNode(metrics, canvas, up: true, right: true, down: true, left: false, filled: true)
        case 0xF605: branchNode(metrics, canvas, up: true, right: true, down: true, left: false, filled: false)
        case 0xF606: branchNode(metrics, canvas, up: true, right: false, down: true, left: true, filled: true)
        case 0xF607: branchNode(metrics, canvas, up: true, right: false, down: true, left: true, filled: false)
        case 0xF608: branchNode(metrics, canvas, up: false, right: true, down: true, left: true, filled: true)
        case 0xF609: branchNode(metrics, canvas, up: false, right: true, down: true, left: true, filled: false)
        case 0xF60A: branchNode(metrics, canvas, up: true, right: true, down: false, left: true, filled: true)
        case 0xF60B: branchNode(metrics, canvas, up: true, right: true, down: false, left: true, filled: false)
        case 0xF60C: branchNode(metrics, canvas, up: true, right: true, down: true, left: true, filled: true)
        case 0xF60D: branchNode(metrics, canvas, up: true, right: true, down: true, left: true, filled: false)
        default: break
        }
    }

    private static func branchNode(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        up: Bool, right: Bool, down: Bool, left: Bool,
        filled: Bool
    ) {
        let thickPx = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let floatWidth = Double(metrics.cellWidth)
        let floatHeight = Double(metrics.cellHeight)
        let floatThick = Double(thickPx)

        let hTop = SpriteCommon.satSub(metrics.cellHeight, thickPx) / 2
        let hBottom = hTop + thickPx
        let vLeft = SpriteCommon.satSub(metrics.cellWidth, thickPx) / 2
        let vRight = vLeft + thickPx

        let cx = Double(vLeft) + floatThick / 2
        let cy = Double(hTop) + floatThick / 2
        let r = min(min(cx, cy), min(floatWidth - cx, floatHeight - cy))

        if up {
            canvas.box(
                x0: vLeft, y0: 0,
                x1: vRight, y1: Int(ceil(cy - r + floatThick / 2)),
                value: 255
            )
        }
        if right {
            canvas.box(
                x0: Int(floor(cx + r - floatThick / 2)), y0: hTop,
                x1: metrics.cellWidth, y1: hBottom,
                value: 255
            )
        }
        if down {
            canvas.box(
                x0: vLeft, y0: Int(floor(cy + r - floatThick / 2)),
                x1: vRight, y1: metrics.cellHeight,
                value: 255
            )
        }
        if left {
            canvas.box(
                x0: 0, y0: hTop,
                x1: Int(ceil(cx - r + floatThick / 2)), y1: hBottom,
                value: 255
            )
        }

        if filled {
            canvas.fillCircle(cx: cx, cy: cy, r: r, value: 255)
        } else {
            canvas.strokeCircle(
                cx: cx, cy: cy,
                r: max(0.5, r - floatThick / 2),
                thickness: floatThick,
                value: 255
            )
        }
    }

    private static func fadingLine(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        to: SpriteCommon.Edge
    ) {
        let thickPx = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let floatWidth = Double(metrics.cellWidth)
        let floatHeight = Double(metrics.cellHeight)

        let hTop = SpriteCommon.satSub(metrics.cellHeight, thickPx) / 2
        let hBottom = hTop + thickPx
        let vLeft = SpriteCommon.satSub(metrics.cellWidth, thickPx) / 2
        let vRight = vLeft + thickPx

        var color: Double
        let inc: Double
        switch to {
        case .top:
            color = 0
            inc = 255.0 / floatHeight
        case .bottom:
            color = 255
            inc = -255.0 / floatHeight
        case .left:
            color = 0
            inc = 255.0 / floatWidth
        case .right:
            color = 255
            inc = -255.0 / floatWidth
        }

        switch to {
        case .top, .bottom:
            for y in 0..<metrics.cellHeight {
                let v = UInt8(min(255, max(0, Int(color.rounded()))))
                for x in vLeft..<vRight {
                    canvas.pixel(x: x, y: y, value: v)
                }
                color += inc
            }
        case .left, .right:
            for x in 0..<metrics.cellWidth {
                let v = UInt8(min(255, max(0, Int(color.rounded()))))
                for y in hTop..<hBottom {
                    canvas.pixel(x: x, y: y, value: v)
                }
                color += inc
            }
        }
    }
}
