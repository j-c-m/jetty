import Carbon.HIToolbox
import simd

/// ghosvt-style centered cell panel for quit / close.
public enum QuitConfirm {
    public enum Mode {
        case quit
        case close
    }

    public enum Reply {
        case ignore
        case yes
        case no
        case swallow
    }

    public static let rows = 4
    public static let cols = 18
    public static var instanceCount: Int { rows * cols }

    public static func lines(mode: Mode) -> [String] {
        let title: String
        switch mode {
        case .quit: title = "Quit Jetty?"
        case .close: title = "Close window?"
        }
        let inner = cols - 2
        let pad = max(0, inner - title.count)
        let left = pad / 2
        let right = pad - left
        let mid = String(repeating: " ", count: left) + title + String(repeating: " ", count: right)
        return [
            "┌────────────────┐",
            "│" + mid + "│",
            "│     y / n      │",
            "└────────────────┘",
        ]
    }

    public static func reply(keyCode: UInt16, characters: String?, command: Bool) -> Reply {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl,
             kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand,
             kVK_Function, kVK_CapsLock:
            return .ignore
        default:
            break
        }
        let ch = characters?.lowercased()
        if command, ch == "q" { return .yes }
        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .yes
        case kVK_Escape:
            return .no
        default:
            break
        }
        switch ch {
        case "y": return .yes
        case "n": return .no
        default: return .swallow
        }
    }

    @discardableResult
    static func write(
        dest: UnsafeMutablePointer<CellInstance>,
        mode: Mode,
        cols: Int,
        rows: Int,
        cellW: Float,
        cellH: Float,
        originX: Float,
        originY: Float,
        contentOffsetY: Float,
        fg: SIMD3<Float>,
        bg: SIMD3<Float>,
        atlas: GlyphAtlas
    ) -> Int {
        let lines = self.lines(mode: mode)
        guard cols > 0, rows > 0 else { return 0 }
        let startCol = max(0, (cols - self.cols) / 2)
        let startRow = max(0, (rows - self.rows) / 2)
        var n = 0
        for (r, line) in lines.enumerated() {
            let row = startRow + r
            guard row < rows else { break }
            let oy = originY + Float(row) * cellH - contentOffsetY
            var col = startCol
            for ch in line {
                guard col < cols else { break }
                let ox = originX + Float(col) * cellW
                var g = GlyphAtlas.Glyph.empty
                if ch != " ",
                   ch.unicodeScalars.count == 1,
                   let us = ch.unicodeScalars.first
                {
                    g = atlas.glyph(scalar: us.value, bold: true, italic: false, wide: false)
                }
                dest[n] = CellInstance(
                    originX: ox,
                    originY: oy,
                    width: cellW,
                    height: cellH,
                    uv: g.uv,
                    fgRGB: fg,
                    bgRGB: bg,
                    colorAtlas: g.color,
                    bgAlpha: 0.95
                )
                n += 1
                col += 1
            }
        }
        return n
    }
}
