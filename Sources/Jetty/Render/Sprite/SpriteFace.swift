import Foundation

/// Ghostty-style built-in sprite face: box drawing, blocks, braille, powerline, etc.
///
/// Ordered drawers — first match wins. Legacy computing omitted until needed.
enum SpriteFace {
    /// True if we procedurally draw this codepoint (do not use a font).
    static func covers(_ cp: UInt32) -> Bool {
        BrailleSprites.covers(cp)
            || BlockSprites.covers(cp)
            || BoxSprites.covers(cp)
            || GeometricSprites.covers(cp)
            || PowerlineSprites.covers(cp)
            || BranchSprites.covers(cp)
    }

    /// Draw into a full-cell R8 coverage buffer. Returns false if not a sprite cp.
    @discardableResult
    static func draw(
        _ cp: UInt32,
        width: Int,
        height: Int,
        baseline: Int,
        into coverage: inout [UInt8]
    ) -> Bool {
        guard covers(cp) else { return false }
        let w = max(1, width)
        let h = max(1, height)
        let metrics = SpriteMetrics(cellWidth: w, cellHeight: h, cellBaseline: baseline)
        let canvas = SpriteCanvas(width: w, height: h)

        if BrailleSprites.covers(cp) {
            BrailleSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if BlockSprites.covers(cp) {
            BlockSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if BoxSprites.covers(cp) {
            BoxSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if GeometricSprites.covers(cp) {
            GeometricSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if PowerlineSprites.covers(cp) {
            PowerlineSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else if BranchSprites.covers(cp) {
            BranchSprites.draw(cp, canvas: canvas, metrics: metrics)
        } else {
            return false
        }

        coverage = canvas.pixels
        if coverage.count != w * h {
            if coverage.count > w * h {
                coverage = Array(coverage.prefix(w * h))
            } else {
                coverage.append(contentsOf: repeatElement(0, count: w * h - coverage.count))
            }
        }
        return true
    }
}
