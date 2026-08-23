import CoreText
import Foundation

// Font registration is process-wide and guarded by `lock`.

public enum EmbeddedFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    public static let familyName = "JetBrainsMono Nerd Font Mono"

    public static func registerIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        for name in faceFiles {
            guard let url = fontURL(name) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    public static func font(size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        registerIfNeeded()
        return bundled(size: size, bold: bold, italic: italic)
    }

    /// Bundled Mono when `family` is omitted, the bundled name, or missing.
    public static func fonts(
        family: String?,
        size: CGFloat
    ) -> (regular: CTFont, bold: CTFont, italic: CTFont, boldItalic: CTFont) {
        registerIfNeeded()
        let want = family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if want.isEmpty || want.caseInsensitiveCompare(familyName) == .orderedSame {
            return bundledFaces(size: size)
        }
        if let sys = systemFaces(family: want, size: size) { return sys }
        warnMissingFamily(want)
        return bundledFaces(size: size)
    }

    private static func bundled(size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let file: String
        switch (bold, italic) {
        case (true, true): file = "JetBrainsMonoNerdFontMono-ExtraBoldItalic.ttf"
        case (true, false): file = "JetBrainsMonoNerdFontMono-ExtraBold.ttf"
        case (false, true): file = "JetBrainsMonoNerdFontMono-Italic.ttf"
        case (false, false): file = "JetBrainsMonoNerdFontMono-Regular.ttf"
        }
        if let font = fontFromFile(file, size: size) { return font }
        return CTFontCreateWithName(familyName as CFString, size, nil)
    }

    private static func bundledFaces(size: CGFloat) -> (
        regular: CTFont, bold: CTFont, italic: CTFont, boldItalic: CTFont
    ) {
        (
            bundled(size: size, bold: false, italic: false),
            bundled(size: size, bold: true, italic: false),
            bundled(size: size, bold: false, italic: true),
            bundled(size: size, bold: true, italic: true)
        )
    }

    private static func familyMatches(_ font: CTFont, _ family: String) -> Bool {
        let got = CTFontCopyFamilyName(font) as String
        return got.caseInsensitiveCompare(family) == .orderedSame
    }

    private static func systemFaces(family: String, size: CGFloat) -> (
        regular: CTFont, bold: CTFont, italic: CTFont, boldItalic: CTFont
    )? {
        let regular = CTFontCreateWithName(family as CFString, size, nil)
        guard familyMatches(regular, family) else { return nil }
        let italic = copyTraits(regular, size: size, traits: .traitItalic) ?? regular
        let bold = heavier(family: family, size: size, italic: false) ?? copyTraits(
            regular, size: size, traits: .traitBold
        ) ?? regular
        let boldItalic = heavier(family: family, size: size, italic: true) ?? copyTraits(
            italic, size: size, traits: .traitBold
        ) ?? italic
        return (regular, bold, italic, boldItalic)
    }

    private static func copyTraits(_ font: CTFont, size: CGFloat, traits: CTFontSymbolicTraits) -> CTFont? {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits)
    }

    private static func heavier(family: String, size: CGFloat, italic: Bool) -> CTFont? {
        for weight in [CGFloat(0.62), 0.56, 0.40] {
            var traits: [CFString: Any] = [kCTFontWeightTrait as CFString: weight]
            if italic {
                traits[kCTFontSymbolicTrait as CFString] = CTFontSymbolicTraits.traitItalic.rawValue
            }
            let attrs: [CFString: Any] = [
                kCTFontFamilyNameAttribute as CFString: family,
                kCTFontTraitsAttribute as CFString: traits,
            ]
            let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(desc, size, nil)
            if familyMatches(font, family) { return font }
        }
        return nil
    }

    private static let warnLock = NSLock()
    nonisolated(unsafe) private static var warnedFamilies = Set<String>()

    private static func warnMissingFamily(_ family: String) {
        warnLock.lock()
        defer { warnLock.unlock() }
        if warnedFamilies.contains(family) { return }
        warnedFamilies.insert(family)
        fputs("jetty: missing font-family \(family)\n", stderr)
    }

    private static let faceFiles = [
        "JetBrainsMonoNerdFontMono-Regular.ttf",
        "JetBrainsMonoNerdFontMono-Italic.ttf",
        "JetBrainsMonoNerdFontMono-Bold.ttf",
        "JetBrainsMonoNerdFontMono-BoldItalic.ttf",
        "JetBrainsMonoNerdFontMono-ExtraBold.ttf",
        "JetBrainsMonoNerdFontMono-ExtraBoldItalic.ttf",
    ]

    private static func fontURL(_ name: String) -> URL? {
        let stem = String(name.dropLast(4))
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/Fonts")
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: stem, withExtension: "ttf", subdirectory: "Resources/Fonts")
            ?? Bundle.module.url(forResource: stem, withExtension: "ttf", subdirectory: "Fonts")
    }

    private static func fontFromFile(_ name: String, size: CGFloat) -> CTFont? {
        guard let url = fontURL(name) else { return nil }
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let desc = descs.first
        else { return nil }
        return CTFontCreateWithFontDescriptor(desc, size, nil)
    }
}
