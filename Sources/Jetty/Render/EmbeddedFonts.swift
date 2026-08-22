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
