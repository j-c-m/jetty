import CoreText

public struct CellMetrics {
    public var cellWidthPx: Int
    public var cellHeightPx: Int
    public var cellBaselinePx: Int
    public var fontSize: CGFloat
    public var fontPx: CGFloat
    public var font: CTFont
    public var fontBold: CTFont
    public var fontItalic: CTFont
    public var fontBoldItalic: CTFont

    public static func measure(fontSize: CGFloat, backingScale: CGFloat) -> CellMetrics {
        let s = max(backingScale, 1)
        let pxSize = fontSize * s
        let regular = EmbeddedFonts.font(size: pxSize, bold: false, italic: false)
        let bold = EmbeddedFonts.font(size: pxSize, bold: true, italic: false)
        let italic = EmbeddedFonts.font(size: pxSize, bold: false, italic: true)
        let boldItalic = EmbeddedFonts.font(size: pxSize, bold: true, italic: true)

        var faceWidth: CGFloat = 0
        for code in 32...126 {
            var ch = UniChar(code)
            var g = CGGlyph()
            guard CTFontGetGlyphsForCharacters(regular, &ch, &g, 1), g != 0 else { continue }
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(regular, .horizontal, &g, &adv, 1)
            faceWidth = max(faceWidth, adv.width)
        }
        if faceWidth < 0.5 { faceWidth = pxSize * 0.6 }

        let ascent = CTFontGetAscent(regular)
        let descent = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        let faceHeight = ascent + descent + leading
        let cellWPx = max(1, Int(faceWidth.rounded()) + 1)
        let cellHPx = max(1, Int(faceHeight.rounded()))
        let halfLineGap = leading / 2
        let faceBaseline = halfLineGap + descent
        let cellBaseline = max(0, Int((faceBaseline - (CGFloat(cellHPx) - faceHeight) / 2).rounded()))

        return CellMetrics(
            cellWidthPx: cellWPx,
            cellHeightPx: cellHPx,
            cellBaselinePx: cellBaseline,
            fontSize: fontSize,
            fontPx: pxSize,
            font: regular,
            fontBold: bold,
            fontItalic: italic,
            fontBoldItalic: boldItalic
        )
    }

    public func face(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (true, true): return fontBoldItalic
        case (true, false): return fontBold
        case (false, true): return fontItalic
        case (false, false): return font
        }
    }
}
