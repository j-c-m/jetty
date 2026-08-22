import Foundation

/// Cell metrics for procedural sprite drawing (device pixels).
struct SpriteMetrics {
    var cellWidth: Int
    var cellHeight: Int
    /// Distance from the bottom of the cell to the text baseline.
    var cellBaseline: Int
    /// Thickness of box-drawing strokes (Ghostty `box_thickness`).
    var boxThickness: Int
    var underlineThickness: Int

    init(
        cellWidth: Int,
        cellHeight: Int,
        cellBaseline: Int = 0,
        boxThickness: Int? = nil,
        underlineThickness: Int = 1
    ) {
        self.cellWidth = max(1, cellWidth)
        self.cellHeight = max(1, cellHeight)
        self.cellBaseline = max(0, min(cellBaseline, self.cellHeight))
        let defaultBox = max(1, self.cellHeight / 16)
        self.boxThickness = max(1, boxThickness ?? defaultBox)
        self.underlineThickness = max(1, underlineThickness)
    }
}
