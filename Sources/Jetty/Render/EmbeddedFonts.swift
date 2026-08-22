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
        let names = [
            "JetBrainsMonoNerdFontMono-Regular.ttf",
            "JetBrainsMonoNerdFontMono-Bold.ttf",
            "JetBrainsMonoNerdFontMono-Italic.ttf",
            "JetBrainsMonoNerdFontMono-BoldItalic.ttf",
        ]
        for name in names {
            let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: String(name.dropLast(4)), withExtension: "ttf", subdirectory: "Resources/Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    public static func font(size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        registerIfNeeded()
        let traits: CTFontSymbolicTraits
        switch (bold, italic) {
        case (true, true): traits = [.traitBold, .traitItalic]
        case (true, false): traits = .traitBold
        case (false, true): traits = .traitItalic
        case (false, false): traits = []
        }
        let base = CTFontCreateWithName(familyName as CFString, size, nil)
        if traits.isEmpty { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }
}
