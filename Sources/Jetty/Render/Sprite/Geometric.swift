import Foundation

/// Geometric corner triangles | U+25E2–25E5, U+25F8–25FA, U+25FF
/// Ghostty `draw/geometric_shapes.zig`
enum GeometricSprites {
    static func covers(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x25E2...0x25E5, 0x25F8...0x25FA, 0x25FF:
            return true
        default:
            return false
        }
    }

    static func draw(_ cp: UInt32, canvas: SpriteCanvas, metrics: SpriteMetrics) {
        switch cp {
        case 0x25E2: cornerTriangleShade(metrics, canvas, .br, .on)
        case 0x25E3: cornerTriangleShade(metrics, canvas, .bl, .on)
        case 0x25E4: cornerTriangleShade(metrics, canvas, .tl, .on)
        case 0x25E5: cornerTriangleShade(metrics, canvas, .tr, .on)
        case 0x25F8: cornerTriangleOutline(metrics, canvas, .tl)
        case 0x25F9: cornerTriangleOutline(metrics, canvas, .tr)
        case 0x25FA: cornerTriangleOutline(metrics, canvas, .bl)
        case 0x25FF: cornerTriangleOutline(metrics, canvas, .br)
        default: break
        }
    }

    private static func cornerTriangleShade(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ corner: SpriteCommon.Corner,
        _ shade: SpriteCommon.Shade
    ) {
        let (p0, p1, p2) = trianglePoints(corner, metrics)
        canvas.fillTriangle(p0: p0, p1: p1, p2: p2, value: shade.rawValue)
    }

    private static func cornerTriangleOutline(
        _ metrics: SpriteMetrics,
        _ canvas: SpriteCanvas,
        _ corner: SpriteCommon.Corner
    ) {
        let thick = Double(SpriteCommon.Thickness.light.height(base: metrics.boxThickness))
        let (p0, p1, p2) = trianglePoints(corner, metrics)
        let path = SpriteCanvas.Path()
        path.moveTo(p0.x, p0.y)
        path.lineTo(p1.x, p1.y)
        path.lineTo(p2.x, p2.y)
        path.close()
        canvas.innerStrokePath(path, thickness: thick, value: 255)
    }

    private static func trianglePoints(
        _ corner: SpriteCommon.Corner,
        _ metrics: SpriteMetrics
    ) -> (SpriteCanvas.Point, SpriteCanvas.Point, SpriteCanvas.Point) {
        let w = Double(metrics.cellWidth)
        let h = Double(metrics.cellHeight)
        switch corner {
        case .tl:
            return (.init(x: 0, y: 0), .init(x: 0, y: h), .init(x: w, y: 0))
        case .tr:
            return (.init(x: 0, y: 0), .init(x: w, y: h), .init(x: w, y: 0))
        case .bl:
            return (.init(x: 0, y: 0), .init(x: 0, y: h), .init(x: w, y: h))
        case .br:
            return (.init(x: 0, y: h), .init(x: w, y: h), .init(x: w, y: 0))
        }
    }
}
