import Foundation

/// Box Drawing | U+2500...U+257F
enum BoxSprites {
    static let codepointRange: ClosedRange<UInt32> = 0x2500...0x257F

    static func covers(_ cp: UInt32) -> Bool {
        codepointRange.contains(cp)
    }

    /// Traditional intersection-style line/box-drawing char.
    struct Lines {
        enum Style {
            case none, light, heavy, double
        }

        var up: Style = .none
        var right: Style = .none
        var down: Style = .none
        var left: Style = .none
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        guard covers(cp) else { return }

        let lightH = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let heavyH = SpriteCommon.Thickness.heavy.height(base: metrics.boxThickness)
        let gap4 = max(4, lightH)

        switch cp {
        case 0x2500: linesChar(metrics, canvas, Lines(right: .light, left: .light))
        case 0x2501: linesChar(metrics, canvas, Lines(right: .heavy, left: .heavy))
        case 0x2502: linesChar(metrics, canvas, Lines(up: .light, down: .light))
        case 0x2503: linesChar(metrics, canvas, Lines(up: .heavy, down: .heavy))
        case 0x2504: dashHorizontal(metrics, canvas, count: 3, thickPx: lightH, desiredGap: gap4)
        case 0x2505: dashHorizontal(metrics, canvas, count: 3, thickPx: heavyH, desiredGap: gap4)
        case 0x2506: dashVertical(metrics, canvas, count: 3, thickPx: lightH, desiredGap: gap4)
        case 0x2507: dashVertical(metrics, canvas, count: 3, thickPx: heavyH, desiredGap: gap4)
        case 0x2508: dashHorizontal(metrics, canvas, count: 4, thickPx: lightH, desiredGap: gap4)
        case 0x2509: dashHorizontal(metrics, canvas, count: 4, thickPx: heavyH, desiredGap: gap4)
        case 0x250A: dashVertical(metrics, canvas, count: 4, thickPx: lightH, desiredGap: gap4)
        case 0x250B: dashVertical(metrics, canvas, count: 4, thickPx: heavyH, desiredGap: gap4)
        case 0x250C: linesChar(metrics, canvas, Lines(right: .light, down: .light))
        case 0x250D: linesChar(metrics, canvas, Lines(right: .heavy, down: .light))
        case 0x250E: linesChar(metrics, canvas, Lines(right: .light, down: .heavy))
        case 0x250F: linesChar(metrics, canvas, Lines(right: .heavy, down: .heavy))

        case 0x2510: linesChar(metrics, canvas, Lines(down: .light, left: .light))
        case 0x2511: linesChar(metrics, canvas, Lines(down: .light, left: .heavy))
        case 0x2512: linesChar(metrics, canvas, Lines(down: .heavy, left: .light))
        case 0x2513: linesChar(metrics, canvas, Lines(down: .heavy, left: .heavy))
        case 0x2514: linesChar(metrics, canvas, Lines(up: .light, right: .light))
        case 0x2515: linesChar(metrics, canvas, Lines(up: .light, right: .heavy))
        case 0x2516: linesChar(metrics, canvas, Lines(up: .heavy, right: .light))
        case 0x2517: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy))
        case 0x2518: linesChar(metrics, canvas, Lines(up: .light, left: .light))
        case 0x2519: linesChar(metrics, canvas, Lines(up: .light, left: .heavy))
        case 0x251A: linesChar(metrics, canvas, Lines(up: .heavy, left: .light))
        case 0x251B: linesChar(metrics, canvas, Lines(up: .heavy, left: .heavy))
        case 0x251C: linesChar(metrics, canvas, Lines(up: .light, right: .light, down: .light))
        case 0x251D: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, down: .light))
        case 0x251E: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, down: .light))
        case 0x251F: linesChar(metrics, canvas, Lines(up: .light, right: .light, down: .heavy))

        case 0x2520: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, down: .heavy))
        case 0x2521: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, down: .light))
        case 0x2522: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, down: .heavy))
        case 0x2523: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, down: .heavy))
        case 0x2524: linesChar(metrics, canvas, Lines(up: .light, down: .light, left: .light))
        case 0x2525: linesChar(metrics, canvas, Lines(up: .light, down: .light, left: .heavy))
        case 0x2526: linesChar(metrics, canvas, Lines(up: .heavy, down: .light, left: .light))
        case 0x2527: linesChar(metrics, canvas, Lines(up: .light, down: .heavy, left: .light))
        case 0x2528: linesChar(metrics, canvas, Lines(up: .heavy, down: .heavy, left: .light))
        case 0x2529: linesChar(metrics, canvas, Lines(up: .heavy, down: .light, left: .heavy))
        case 0x252A: linesChar(metrics, canvas, Lines(up: .light, down: .heavy, left: .heavy))
        case 0x252B: linesChar(metrics, canvas, Lines(up: .heavy, down: .heavy, left: .heavy))
        case 0x252C: linesChar(metrics, canvas, Lines(right: .light, down: .light, left: .light))
        case 0x252D: linesChar(metrics, canvas, Lines(right: .light, down: .light, left: .heavy))
        case 0x252E: linesChar(metrics, canvas, Lines(right: .heavy, down: .light, left: .light))
        case 0x252F: linesChar(metrics, canvas, Lines(right: .heavy, down: .light, left: .heavy))

        case 0x2530: linesChar(metrics, canvas, Lines(right: .light, down: .heavy, left: .light))
        case 0x2531: linesChar(metrics, canvas, Lines(right: .light, down: .heavy, left: .heavy))
        case 0x2532: linesChar(metrics, canvas, Lines(right: .heavy, down: .heavy, left: .light))
        case 0x2533: linesChar(metrics, canvas, Lines(right: .heavy, down: .heavy, left: .heavy))
        case 0x2534: linesChar(metrics, canvas, Lines(up: .light, right: .light, left: .light))
        case 0x2535: linesChar(metrics, canvas, Lines(up: .light, right: .light, left: .heavy))
        case 0x2536: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, left: .light))
        case 0x2537: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, left: .heavy))
        case 0x2538: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, left: .light))
        case 0x2539: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, left: .heavy))
        case 0x253A: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, left: .light))
        case 0x253B: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, left: .heavy))
        case 0x253C: linesChar(metrics, canvas, Lines(up: .light, right: .light, down: .light, left: .light))
        case 0x253D: linesChar(metrics, canvas, Lines(up: .light, right: .light, down: .light, left: .heavy))
        case 0x253E: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, down: .light, left: .light))
        case 0x253F: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, down: .light, left: .heavy))

        case 0x2540: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, down: .light, left: .light))
        case 0x2541: linesChar(metrics, canvas, Lines(up: .light, right: .light, down: .heavy, left: .light))
        case 0x2542: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, down: .heavy, left: .light))
        case 0x2543: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, down: .light, left: .heavy))
        case 0x2544: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, down: .light, left: .light))
        case 0x2545: linesChar(metrics, canvas, Lines(up: .light, right: .light, down: .heavy, left: .heavy))
        case 0x2546: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, down: .heavy, left: .light))
        case 0x2547: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, down: .light, left: .heavy))
        case 0x2548: linesChar(metrics, canvas, Lines(up: .light, right: .heavy, down: .heavy, left: .heavy))
        case 0x2549: linesChar(metrics, canvas, Lines(up: .heavy, right: .light, down: .heavy, left: .heavy))
        case 0x254A: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, down: .heavy, left: .light))
        case 0x254B: linesChar(metrics, canvas, Lines(up: .heavy, right: .heavy, down: .heavy, left: .heavy))
        case 0x254C: dashHorizontal(metrics, canvas, count: 2, thickPx: lightH, desiredGap: lightH)
        case 0x254D: dashHorizontal(metrics, canvas, count: 2, thickPx: heavyH, desiredGap: heavyH)
        case 0x254E: dashVertical(metrics, canvas, count: 2, thickPx: lightH, desiredGap: heavyH)
        case 0x254F: dashVertical(metrics, canvas, count: 2, thickPx: heavyH, desiredGap: heavyH)

        case 0x2550: linesChar(metrics, canvas, Lines(right: .double, left: .double))
        case 0x2551: linesChar(metrics, canvas, Lines(up: .double, down: .double))
        case 0x2552: linesChar(metrics, canvas, Lines(right: .double, down: .light))
        case 0x2553: linesChar(metrics, canvas, Lines(right: .light, down: .double))
        case 0x2554: linesChar(metrics, canvas, Lines(right: .double, down: .double))
        case 0x2555: linesChar(metrics, canvas, Lines(down: .light, left: .double))
        case 0x2556: linesChar(metrics, canvas, Lines(down: .double, left: .light))
        case 0x2557: linesChar(metrics, canvas, Lines(down: .double, left: .double))
        case 0x2558: linesChar(metrics, canvas, Lines(up: .light, right: .double))
        case 0x2559: linesChar(metrics, canvas, Lines(up: .double, right: .light))
        case 0x255A: linesChar(metrics, canvas, Lines(up: .double, right: .double))
        case 0x255B: linesChar(metrics, canvas, Lines(up: .light, left: .double))
        case 0x255C: linesChar(metrics, canvas, Lines(up: .double, left: .light))
        case 0x255D: linesChar(metrics, canvas, Lines(up: .double, left: .double))
        case 0x255E: linesChar(metrics, canvas, Lines(up: .light, right: .double, down: .light))
        case 0x255F: linesChar(metrics, canvas, Lines(up: .double, right: .light, down: .double))

        case 0x2560: linesChar(metrics, canvas, Lines(up: .double, right: .double, down: .double))
        case 0x2561: linesChar(metrics, canvas, Lines(up: .light, down: .light, left: .double))
        case 0x2562: linesChar(metrics, canvas, Lines(up: .double, down: .double, left: .light))
        case 0x2563: linesChar(metrics, canvas, Lines(up: .double, down: .double, left: .double))
        case 0x2564: linesChar(metrics, canvas, Lines(right: .double, down: .light, left: .double))
        case 0x2565: linesChar(metrics, canvas, Lines(right: .light, down: .double, left: .light))
        case 0x2566: linesChar(metrics, canvas, Lines(right: .double, down: .double, left: .double))
        case 0x2567: linesChar(metrics, canvas, Lines(up: .light, right: .double, left: .double))
        case 0x2568: linesChar(metrics, canvas, Lines(up: .double, right: .light, left: .light))
        case 0x2569: linesChar(metrics, canvas, Lines(up: .double, right: .double, left: .double))
        case 0x256A: linesChar(metrics, canvas, Lines(up: .light, right: .double, down: .light, left: .double))
        case 0x256B: linesChar(metrics, canvas, Lines(up: .double, right: .light, down: .double, left: .light))
        case 0x256C: linesChar(metrics, canvas, Lines(up: .double, right: .double, down: .double, left: .double))
        case 0x256D: arc(metrics, canvas, SpriteCommon.Corner.br, .light)
        case 0x256E: arc(metrics, canvas, SpriteCommon.Corner.bl, .light)
        case 0x256F: arc(metrics, canvas, SpriteCommon.Corner.tl, .light)

        case 0x2570: arc(metrics, canvas, SpriteCommon.Corner.tr, .light)
        case 0x2571: lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        case 0x2572: lightDiagonalUpperLeftToLowerRight(metrics, canvas)
        case 0x2573: lightDiagonalCross(metrics, canvas)
        case 0x2574: linesChar(metrics, canvas, Lines(left: .light))
        case 0x2575: linesChar(metrics, canvas, Lines(up: .light))
        case 0x2576: linesChar(metrics, canvas, Lines(right: .light))
        case 0x2577: linesChar(metrics, canvas, Lines(down: .light))
        case 0x2578: linesChar(metrics, canvas, Lines(left: .heavy))
        case 0x2579: linesChar(metrics, canvas, Lines(up: .heavy))
        case 0x257A: linesChar(metrics, canvas, Lines(right: .heavy))
        case 0x257B: linesChar(metrics, canvas, Lines(down: .heavy))
        case 0x257C: linesChar(metrics, canvas, Lines(right: .heavy, left: .light))
        case 0x257D: linesChar(metrics, canvas, Lines(up: .light, down: .heavy))
        case 0x257E: linesChar(metrics, canvas, Lines(right: .light, left: .heavy))
        case 0x257F: linesChar(metrics, canvas, Lines(up: .heavy, down: .light))
        default: break
        }
    }

    // MARK: - linesChar (core box-drawing)

    static func linesChar(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ lines: Lines
    ) {
        let sat = SpriteCommon.satSub
        let lightPx = SpriteCommon.Thickness.light.height(base: metrics.boxThickness)
        let heavyPx = SpriteCommon.Thickness.heavy.height(base: metrics.boxThickness)

        let hLightTop = sat(metrics.cellHeight, lightPx) / 2
        let hLightBottom = hLightTop + lightPx
        let hHeavyTop = sat(metrics.cellHeight, heavyPx) / 2
        let hHeavyBottom = hHeavyTop + heavyPx
        let hDoubleTop = sat(hLightTop, lightPx)
        let hDoubleBottom = hLightBottom + lightPx

        let vLightLeft = sat(metrics.cellWidth, lightPx) / 2
        let vLightRight = vLightLeft + lightPx
        let vHeavyLeft = sat(metrics.cellWidth, heavyPx) / 2
        let vHeavyRight = vHeavyLeft + heavyPx
        let vDoubleLeft = sat(vLightLeft, lightPx)
        let vDoubleRight = vLightRight + lightPx

        let upBottom: Int
        if lines.left == .heavy || lines.right == .heavy {
            upBottom = hHeavyBottom
        } else if lines.left != lines.right || lines.down == lines.up {
            if lines.left == .double || lines.right == .double {
                upBottom = hDoubleBottom
            } else {
                upBottom = hLightBottom
            }
        } else if lines.left == .none && lines.right == .none {
            upBottom = hLightBottom
        } else {
            upBottom = hLightTop
        }

        let downTop: Int
        if lines.left == .heavy || lines.right == .heavy {
            downTop = hHeavyTop
        } else if lines.left != lines.right || lines.up == lines.down {
            if lines.left == .double || lines.right == .double {
                downTop = hDoubleTop
            } else {
                downTop = hLightTop
            }
        } else if lines.left == .none && lines.right == .none {
            downTop = hLightTop
        } else {
            downTop = hLightBottom
        }

        let leftRight: Int
        if lines.up == .heavy || lines.down == .heavy {
            leftRight = vHeavyRight
        } else if lines.up != lines.down || lines.left == lines.right {
            if lines.up == .double || lines.down == .double {
                leftRight = vDoubleRight
            } else {
                leftRight = vLightRight
            }
        } else if lines.up == .none && lines.down == .none {
            leftRight = vLightRight
        } else {
            leftRight = vLightLeft
        }

        let rightLeft: Int
        if lines.up == .heavy || lines.down == .heavy {
            rightLeft = vHeavyLeft
        } else if lines.up != lines.down || lines.right == lines.left {
            if lines.up == .double || lines.down == .double {
                rightLeft = vDoubleLeft
            } else {
                rightLeft = vLightLeft
            }
        } else if lines.up == .none && lines.down == .none {
            rightLeft = vLightLeft
        } else {
            rightLeft = vLightRight
        }

        switch lines.up {
        case .none: break
        case .light:
            canvas.box(x0: vLightLeft, y0: 0, x1: vLightRight, y1: upBottom, value: 255)
        case .heavy:
            canvas.box(x0: vHeavyLeft, y0: 0, x1: vHeavyRight, y1: upBottom, value: 255)
        case .double:
            let leftBottom = lines.left == .double ? hLightTop : upBottom
            let rightBottom = lines.right == .double ? hLightTop : upBottom
            canvas.box(x0: vDoubleLeft, y0: 0, x1: vLightLeft, y1: leftBottom, value: 255)
            canvas.box(x0: vLightRight, y0: 0, x1: vDoubleRight, y1: rightBottom, value: 255)
        }

        switch lines.right {
        case .none: break
        case .light:
            canvas.box(x0: rightLeft, y0: hLightTop, x1: metrics.cellWidth, y1: hLightBottom, value: 255)
        case .heavy:
            canvas.box(x0: rightLeft, y0: hHeavyTop, x1: metrics.cellWidth, y1: hHeavyBottom, value: 255)
        case .double:
            let topLeft = lines.up == .double ? vLightRight : rightLeft
            let bottomLeft = lines.down == .double ? vLightRight : rightLeft
            canvas.box(x0: topLeft, y0: hDoubleTop, x1: metrics.cellWidth, y1: hLightTop, value: 255)
            canvas.box(x0: bottomLeft, y0: hLightBottom, x1: metrics.cellWidth, y1: hDoubleBottom, value: 255)
        }

        switch lines.down {
        case .none: break
        case .light:
            canvas.box(x0: vLightLeft, y0: downTop, x1: vLightRight, y1: metrics.cellHeight, value: 255)
        case .heavy:
            canvas.box(x0: vHeavyLeft, y0: downTop, x1: vHeavyRight, y1: metrics.cellHeight, value: 255)
        case .double:
            let leftTop = lines.left == .double ? hLightBottom : downTop
            let rightTop = lines.right == .double ? hLightBottom : downTop
            canvas.box(x0: vDoubleLeft, y0: leftTop, x1: vLightLeft, y1: metrics.cellHeight, value: 255)
            canvas.box(x0: vLightRight, y0: rightTop, x1: vDoubleRight, y1: metrics.cellHeight, value: 255)
        }

        switch lines.left {
        case .none: break
        case .light:
            canvas.box(x0: 0, y0: hLightTop, x1: leftRight, y1: hLightBottom, value: 255)
        case .heavy:
            canvas.box(x0: 0, y0: hHeavyTop, x1: leftRight, y1: hHeavyBottom, value: 255)
        case .double:
            let topRight = lines.up == .double ? vLightLeft : leftRight
            let bottomRight = lines.down == .double ? vLightLeft : leftRight
            canvas.box(x0: 0, y0: hDoubleTop, x1: topRight, y1: hLightTop, value: 255)
            canvas.box(x0: 0, y0: hLightBottom, x1: bottomRight, y1: hDoubleBottom, value: 255)
        }
    }

    // MARK: - Diagonals

    static func lightDiagonalUpperRightToLowerLeft(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas
    ) {
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let slopeX = min(1.0, fw / fh)
        let slopeY = min(1.0, fh / fw)
        let thick = Double(SpriteCommon.Thickness.light.height(base: metrics.boxThickness))
        let p0 = SpriteCanvas.Point(x: fw + 0.5 * slopeX, y: -0.5 * slopeY)
        let p1 = SpriteCanvas.Point(x: -0.5 * slopeX, y: fh + 0.5 * slopeY)
        canvas.strokeLine(p0, p1, thickness: thick)
    }

    static func lightDiagonalUpperLeftToLowerRight(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas
    ) {
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let slopeX = min(1.0, fw / fh)
        let slopeY = min(1.0, fh / fw)
        let thick = Double(SpriteCommon.Thickness.light.height(base: metrics.boxThickness))
        let p0 = SpriteCanvas.Point(x: -0.5 * slopeX, y: -0.5 * slopeY)
        let p1 = SpriteCanvas.Point(x: fw + 0.5 * slopeX, y: fh + 0.5 * slopeY)
        canvas.strokeLine(p0, p1, thickness: thick)
    }

    static func lightDiagonalCross(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas
    ) {
        lightDiagonalUpperRightToLowerLeft(metrics, canvas)
        lightDiagonalUpperLeftToLowerRight(metrics, canvas)
    }

    // MARK: - Arc corners

    static func arc(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ corner: SpriteCommon.Corner,
        _ thickness: SpriteCommon.Thickness
    ) {
        let thickPx = thickness.height(base: metrics.boxThickness)
        let fw = Double(metrics.cellWidth)
        let fh = Double(metrics.cellHeight)
        let floatThick = Double(thickPx)
        let centerX = Double(SpriteCommon.satSub(metrics.cellWidth, thickPx) / 2) + floatThick / 2
        let centerY = Double(SpriteCommon.satSub(metrics.cellHeight, thickPx) / 2) + floatThick / 2
        let r = min(fw, fh) / 2
        let s: Double = 0.25

        let path = SpriteCanvas.Path()
        switch corner {
        case .tl:
            path.moveTo(centerX, 0)
            path.lineTo(centerX, centerY - r)
            path.curveTo(
                centerX, centerY - s * r,
                centerX - s * r, centerY,
                centerX - r, centerY
            )
            path.lineTo(0, centerY)
        case .tr:
            path.moveTo(centerX, 0)
            path.lineTo(centerX, centerY - r)
            path.curveTo(
                centerX, centerY - s * r,
                centerX + s * r, centerY,
                centerX + r, centerY
            )
            path.lineTo(fw, centerY)
        case .bl:
            path.moveTo(centerX, fh)
            path.lineTo(centerX, centerY + r)
            path.curveTo(
                centerX, centerY + s * r,
                centerX - s * r, centerY,
                centerX - r, centerY
            )
            path.lineTo(0, centerY)
        case .br:
            path.moveTo(centerX, fh)
            path.lineTo(centerX, centerY + r)
            path.curveTo(
                centerX, centerY + s * r,
                centerX + s * r, centerY,
                centerX + r, centerY
            )
            path.lineTo(fw, centerY)
        }
        canvas.strokePath(path, thickness: floatThick, value: 255)
    }

    // MARK: - Dashes

    private static func dashHorizontal(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        count: Int,
        thickPx: Int,
        desiredGap: Int
    ) {
        precondition(count >= 2 && count <= 4)
        let gapCount = count
        if metrics.cellWidth < count + gapCount {
            SpriteCommon.hlineMiddle(metrics, canvas, thickness: SpriteCommon.Thickness.light)
            return
        }

        let gapWidth = min(desiredGap, metrics.cellWidth / (2 * count))
        let totalGapWidth = gapCount * gapWidth
        let totalDashWidth = metrics.cellWidth - totalGapWidth
        let dashWidth = totalDashWidth / count
        var remaining = totalDashWidth % count

        let y = SpriteCommon.satSub(metrics.cellHeight, thickPx) / 2
        var x = gapWidth / 2

        for _ in 0..<count {
            var x1 = x + dashWidth
            if remaining > 0 {
                remaining -= 1
                x1 += 1
            }
            SpriteCommon.hline(canvas, x1: x, x2: x1, y: y, thicknessPx: thickPx)
            x = x1 + gapWidth
        }
    }

    private static func dashVertical(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        count: Int,
        thickPx: Int,
        desiredGap: Int
    ) {
        precondition(count >= 2 && count <= 4)
        let gapCount = count
        if metrics.cellHeight < count + gapCount {
            SpriteCommon.vlineMiddle(metrics, canvas, thickness: SpriteCommon.Thickness.light)
            return
        }

        let gapHeight = min(desiredGap, metrics.cellHeight / (2 * count))
        let totalGapHeight = gapCount * gapHeight
        let totalDashHeight = metrics.cellHeight - totalGapHeight
        let dashHeight = totalDashHeight / count
        var remaining = totalDashHeight % count

        let x = SpriteCommon.satSub(metrics.cellWidth, thickPx) / 2
        var y = 0

        for _ in 0..<count {
            var y1 = y + dashHeight
            if remaining > 0 {
                remaining -= 1
                y1 += 1
            }
            SpriteCommon.vline(canvas, y1: y, y2: y1, x: x, thicknessPx: thickPx)
            y = y1 + gapHeight
        }
    }
}
