import AppKit
import Carbon
import CVt
import Foundation

public struct AppConfig: Sendable {
    /// Compiled default fg/bg when config omits `foreground` / `background`.
    public static let compiledForeground: UInt32 = 0xCCCCCC
    public static let compiledBackground: UInt32 = 0x000000

    public var fontFamily: String? = nil
    public var fontSize: CGFloat = 20
    public var ligatures: Ligatures = .programming
    public var fontFeature: String = ""
    public var adjustCellWidth: Int = 0
    public var adjustCellHeight: Int = 0
    public var backgroundOpacity: CGFloat = 1
    /// Default fg/bg/cursor as 0xRRGGBB. Nil keeps compiled / DECSCUSR-default.
    public var foreground: UInt32? = nil
    public var background: UInt32? = nil
    public var cursorColor: UInt32? = nil
    public var cursorStyle: CursorStyle = .block
    public var cursorStyleBlink: Bool = false
    public var paletteOverlay: [UInt32] = Array(repeating: 0, count: 16)
    public var paletteOverlayMask: UInt16 = 0
    public var linkURL: Bool = true
    public var desktopNotifications: Bool = true
    public var progressStyle: Bool = true
    public var macosAutoSecureInput: Bool = true
    public var macosAppleScript: Bool = true
    public var macosOptionAsAlt: OptionAsAlt = .unset
    public var windowPaddingLeft: CGFloat = 4
    public var windowPaddingRight: CGFloat = 4
    public var windowPaddingTop: CGFloat = 4
    public var windowPaddingBottom: CGFloat = 4
    public var windowWidth: Int? = nil
    public var windowHeight: Int? = nil
    public var scrollbackLines: Int = 50_000
    public var copyOnSelect: Bool = true
    public var command: String? = nil
    public var workingDirectory: WorkingDirectory = .unset
    public var env: [String: String] = [:]
    public var clipboardPasteProtection: Bool = true
    public var confirmCloseSurface: ConfirmClose = .on

    /// `window-width` / `window-height` (cells). Both required; else 105×35.
    public var launchCols: Int {
        guard windowWidth != nil, windowHeight != nil else { return 105 }
        return max(10, windowWidth!)
    }

    public var launchRows: Int {
        guard windowWidth != nil, windowHeight != nil else { return 35 }
        return max(4, windowHeight!)
    }
    public var osc52Write: Osc52Write = .allow
    public var osc52Read: Osc52Read = .ask
    public var keybinds: [String] = []
    public var kittyGraphics: Bool = true
    public var shellIntegration: ShellIntegration = .detect
    public var notifyOnCommandFinish: NotifyWhen = .never
    public var notifyOnCommandFinishAfter: TimeInterval = 5
    public var notifyOnCommandFinishBell: Bool = true
    public var notifyOnCommandFinishDesktop: Bool = false

    public enum ShellIntegration: Sendable, Equatable {
        case none, detect, bash, zsh, fish, nu
    }

    public enum NotifyWhen: Sendable, Equatable {
        case never, unfocused, always
    }

    public enum Ligatures: Sendable, Equatable {
        /// Cell-boxed letters. No run `CTLine`.
        case off
        /// Hardcoded programming spans only (`=>`, `!=`, …). Letters stay cell-boxed.
        case programming
        /// Shape each run (liga+calt). Can change 1:1 glyphs.
        case on
    }

    public enum Osc52Write: Sendable {
        case allow, deny
    }

    public enum Osc52Read: Sendable {
        case ask, deny
    }

    /// `macos-option-as-alt`: unset follows US / US International.
    public enum OptionAsAlt: Sendable, Equatable {
        case unset, off, on, left, right
    }

    /// `cursor-style`. Default `block`.
    public enum CursorStyle: Sendable, Equatable {
        case block, bar, underline, blockHollow
    }

    /// `working-directory`: unset is inherit, Finder/`open` → home.
    public enum WorkingDirectory: Sendable, Equatable {
        case unset, home, inherit, path(String)
    }

    /// `confirm-close-surface`: `true` / `false` / `always`.
    public enum ConfirmClose: Sendable, Equatable {
        case off, on, always
    }

    static let leftOptionMask: UInt = 0x0000_0020
    static let rightOptionMask: UInt = 0x0000_0040
    static let defaultPadPt: CGFloat = 4

    public static func usKeyboardLayout() -> Bool {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return false
        }
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else {
            return false
        }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id == "com.apple.keylayout.US"
            || id == "com.apple.keylayout.USInternational-PC"
    }

    public func optionAsAltActive(
        optionDown: Bool,
        leftOption: Bool,
        rightOption: Bool,
        usLayout: Bool
    ) -> Bool {
        switch macosOptionAsAlt {
        case .unset: return optionDown && usLayout
        case .off: return false
        case .on: return optionDown
        case .left: return leftOption
        case .right: return rightOption
        }
    }

    public func optionAsAltActive(_ event: NSEvent, usLayout: Bool = AppConfig.usKeyboardLayout()) -> Bool {
        let flags = event.modifierFlags
        return optionAsAltActive(
            optionDown: flags.contains(.option),
            leftOption: flags.rawValue & Self.leftOptionMask != 0,
            rightOption: flags.rawValue & Self.rightOptionMask != 0,
            usLayout: usLayout
        )
    }

    /// Tagged `COLOR_RGB` for the C screen. Compiled defaults when unset.
    public var packedForeground: UInt32 { COLOR_RGB | (foreground ?? Self.compiledForeground) }
    public var packedBackground: UInt32 { COLOR_RGB | (background ?? Self.compiledBackground) }
    public var packedCursor: UInt32 {
        if let rgb = cursorColor { return COLOR_RGB | rgb }
        return COLOR_DEFAULT
    }

    public var envAssignments: [String] {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
    }

    public func resolvedWorkingDirectory() -> String? {
        switch workingDirectory {
        case .unset:
            return nil
        case .inherit:
            return FileManager.default.currentDirectoryPath
        case .home:
            return NSHomeDirectory()
        case .path(let raw):
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return path
        }
    }

    /// DECSCUSR 1–6. Blink is the odd number. Hollow is a paint flag on `block`.
    public var packedCursorStyle: UInt8 {
        let blink = cursorStyleBlink
        switch cursorStyle {
        case .block, .blockHollow: return blink ? 1 : 2
        case .underline: return blink ? 3 : 4
        case .bar: return blink ? 5 : 6
        }
    }

    public var cursorHollow: Bool { cursorStyle == .blockHollow }

    public static var systemDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    public static func load() -> AppConfig {
        let url = configURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return AppConfig() }
        return parse(text)
    }

    public static func parse(
        _ text: String,
        dark: Bool = systemDark,
        loadTheme: ((String) -> String?)? = nil
    ) -> AppConfig {
        let pairs = keyValues(text)
        var c = AppConfig()
        if let spec = lastValue(pairs, key: "theme"), !spec.isEmpty,
           let name = resolveThemeName(spec, dark: dark)
        {
            let loader = loadTheme ?? readThemeFile
            if let body = loader(name) {
                apply(keyValues(body), into: &c)
            }
        }
        apply(pairs, into: &c)
        return c
    }

    public static func configURL() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() + "/.config")
        return URL(fileURLWithPath: base).appendingPathComponent("jetty/config")
    }

    public static func clipboardPasswordsURL() -> URL {
        configURL().deletingLastPathComponent().appendingPathComponent("clipboard-passwords")
    }

    @discardableResult
    public static func ensureConfigFile(at url: URL = configURL()) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    @discardableResult
    public static func ensureClipboardPasswordsFile(
        at url: URL = clipboardPasswordsURL()
    ) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func editorCommand(
        env: [String: String] = ProcessInfo.processInfo.environment,
        sessionEditor: String? = nil
    ) -> String? {
        if let s = sessionEditor?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        for key in ["VISUAL", "EDITOR"] {
            let e = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !e.isEmpty { return e }
        }
        return nil
    }

    public static func openConfigShellCommand(
        path: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        editor: String? = nil
    ) -> String? {
        guard let editor = editorCommand(env: env, sessionEditor: editor) else { return nil }
        return "exec \(editor) \(shellSingleQuote(path))"
    }

    public static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func parseBool(_ s: String) -> Bool {
        ["true", "1", "yes"].contains(s.lowercased())
    }

    /// `cursor-style`: `block` / `bar` / `underline` / `block_hollow`.
    public static func parseCursorStyle(_ raw: String) -> CursorStyle? {
        switch unquote(raw).lowercased() {
        case "block": return .block
        case "bar": return .bar
        case "underline": return .underline
        case "block_hollow": return .blockHollow
        default: return nil
        }
    }

    public static func parseTrueFalse(_ raw: String) -> Bool? {
        switch unquote(raw).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    /// `cursor-style-blink`: `true` / `false`. Empty resets to no blink.
    public static func parseCursorBlink(_ raw: String) -> Bool? {
        parseTrueFalse(raw)
    }

    public static func parseConfirmClose(_ raw: String) -> ConfirmClose? {
        let v = unquote(raw).lowercased()
        if v == "always" { return .always }
        if let b = parseTrueFalse(v) { return b ? .on : .off }
        return nil
    }

    public static func parseWorkingDirectory(_ raw: String) -> WorkingDirectory {
        let v = unquote(raw)
        if v.isEmpty { return .unset }
        switch v.lowercased() {
        case "home": return .home
        case "inherit": return .inherit
        default: return .path(v)
        }
    }

    static func applyEnvEntry(_ raw: String, into c: inout AppConfig) {
        if raw.isEmpty {
            c.env.removeAll()
            return
        }
        guard let eq = raw.firstIndex(of: "=") else { return }
        let key = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
        let val = String(raw[raw.index(after: eq)...])
        if key.isEmpty { return }
        if val.isEmpty {
            c.env.removeValue(forKey: key)
        } else {
            c.env[key] = val
        }
    }

    /// `macos-option-as-alt`: `true` / `false` / `left` / `right`.
    public static func parseOptionAsAlt(_ raw: String) -> OptionAsAlt? {
        switch unquote(raw).lowercased() {
        case "true", "1", "yes", "on": return .on
        case "false", "0", "no", "off": return .off
        case "left": return .left
        case "right": return .right
        default: return nil
        }
    }

    /// `window-padding-x` / `y`: `2` or `2,4` in points.
    public static func parsePadPair(_ raw: String) -> (CGFloat, CGFloat)? {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let n = Double(parts[0]), n.isFinite {
            let v = CGFloat(max(0, n))
            return (v, v)
        }
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]),
           a.isFinite, b.isFinite
        {
            return (CGFloat(max(0, a)), CGFloat(max(0, b)))
        }
        return nil
    }

    public static func parseOnOff(_ s: String) -> Bool {
        let v = s.lowercased()
        if ["false", "0", "no", "off"].contains(v) { return false }
        if ["true", "1", "yes", "on"].contains(v) { return true }
        return true
    }

    public static func parseLigatures(_ s: String) -> Ligatures? {
        switch s.lowercased() {
        case "off", "false", "0", "no": return .off
        case "programming": return .programming
        case "on", "true", "1", "yes": return .on
        default: return nil
        }
    }

    public static func parseShellIntegration(_ s: String) -> ShellIntegration? {
        switch s.lowercased() {
        case "none", "off", "false", "0", "no": return ShellIntegration.none
        case "detect": return .detect
        case "bash": return .bash
        case "zsh": return .zsh
        case "fish": return .fish
        case "nu", "nushell": return .nu
        default: return nil
        }
    }

    public static func parseNotifyWhen(_ s: String) -> NotifyWhen? {
        switch s.lowercased() {
        case "never", "off", "false", "0", "no": return .never
        case "unfocused": return .unfocused
        case "always", "on", "true", "1", "yes": return .always
        default: return nil
        }
    }

    /// Duration: `1h30m`, `45s`, `500ms`. A bare number is seconds.
    public static func parseSeconds(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "µs", with: "us")
            .replacingOccurrences(of: "μs", with: "us")
        if s.isEmpty { return nil }
        var i = s.startIndex
        var total: TimeInterval = 0
        var tokens = 0
        func skipWS() {
            while i < s.endIndex, s[i].isWhitespace {
                i = s.index(after: i)
            }
        }
        while i < s.endIndex {
            skipWS()
            if i >= s.endIndex { break }
            let numStart = i
            var seenDot = false
            while i < s.endIndex {
                let c = s[i]
                if c.isNumber {
                    i = s.index(after: i)
                    continue
                }
                if c == ".", !seenDot {
                    seenDot = true
                    i = s.index(after: i)
                    continue
                }
                break
            }
            if i == numStart { return nil }
            guard let n = Double(s[numStart..<i]), n >= 0 else { return nil }
            skipWS()
            let unit: TimeInterval
            let rest = s[i...]
            if rest.hasPrefix("ms") {
                unit = 0.001
                i = s.index(i, offsetBy: 2)
            } else if rest.hasPrefix("us") {
                unit = 0.000001
                i = s.index(i, offsetBy: 2)
            } else if rest.hasPrefix("ns") {
                unit = 1e-9
                i = s.index(i, offsetBy: 2)
            } else if i < s.endIndex {
                switch s[i] {
                case "y": unit = 365 * 86_400
                case "d": unit = 86_400
                case "h": unit = 3_600
                case "m": unit = 60
                case "s": unit = 1
                default: return nil
                }
                i = s.index(after: i)
            } else if tokens == 0 {
                unit = 1
            } else {
                return nil
            }
            total += n * unit
            tokens += 1
        }
        return tokens > 0 ? total : nil
    }

    public static func parseNotifyAction(_ raw: String, into c: inout AppConfig) {
        for part in raw.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            switch p {
            case "bell": c.notifyOnCommandFinishBell = true
            case "no-bell": c.notifyOnCommandFinishBell = false
            case "notify": c.notifyOnCommandFinishDesktop = true
            case "no-notify": c.notifyOnCommandFinishDesktop = false
            default: break
            }
        }
    }

    public static func parseHexRGB(_ raw: String) -> UInt32? {
        parseColor(raw)
    }

    /// Color: `#RGB`, `#RRGGBB`, `RRGGBB`, or a small X11 name set.
    public static func parseColor(_ raw: String) -> UInt32? {
        var s = unquote(raw)
        if s.isEmpty { return nil }
        if let named = x11Color[s.lowercased()] { return named }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.unicodeScalars.allSatisfy({ $0.isASCII && isHex($0) }) else { return nil }
        switch s.count {
        case 3:
            let chars = Array(s)
            let exp = String([chars[0], chars[0], chars[1], chars[1], chars[2], chars[2]])
            return UInt32(exp, radix: 16)
        case 6:
            return UInt32(s, radix: 16)
        default:
            return nil
        }
    }

    static func unquote(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2 {
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s = String(s.dropFirst().dropLast())
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func keyValues(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            out.append((key, val))
        }
        return out
    }

    static func lastValue(_ pairs: [(String, String)], key: String) -> String? {
        var found: String?
        for (k, v) in pairs where k == key { found = v }
        return found
    }

    /// `light:Name,dark:Name` (order free) or a single theme name.
    public static func resolveThemeName(_ raw: String, dark: Bool) -> String? {
        let v = unquote(raw)
        if v.isEmpty { return nil }
        var light: String?
        var darkName: String?
        for part in v.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            let lower = p.lowercased()
            if lower.hasPrefix("light:") {
                light = unquote(String(p.dropFirst(6)))
            } else if lower.hasPrefix("dark:") {
                darkName = unquote(String(p.dropFirst(5)))
            }
        }
        if let light, let darkName {
            let name = dark ? darkName : light
            return name.isEmpty ? nil : name
        }
        return v
    }

    public static func themeURL(named name: String) -> URL? {
        let trimmed = unquote(name)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("/") {
            let u = URL(fileURLWithPath: trimmed)
            return FileManager.default.isReadableFile(atPath: u.path) ? u : nil
        }
        if trimmed.contains("/") { return nil }
        for dir in themeSearchDirs() {
            let u = dir.appendingPathComponent(trimmed)
            if FileManager.default.isReadableFile(atPath: u.path) { return u }
        }
        return nil
    }

    public static func readThemeFile(_ name: String) -> String? {
        guard let url = themeURL(named: name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func themeSearchDirs() -> [URL] {
        let jetty = configURL().deletingLastPathComponent().appendingPathComponent("themes")
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() + "/.config")
        let ghostty = URL(fileURLWithPath: base).appendingPathComponent("ghostty/themes")
        return [jetty, ghostty]
    }

    static func apply(_ pairs: [(String, String)], into c: inout AppConfig) {
        for (key, val) in pairs {
            apply(key: key, value: val, into: &c)
        }
    }

    static func apply(key: String, value val: String, into c: inout AppConfig) {
        switch key {
        case "theme":
            break
        case "font-family":
            let name = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            c.fontFamily = name.isEmpty ? nil : name
        case "font-size":
            if let n = Double(val) { c.fontSize = CGFloat(min(72, max(8, n))) }
        case "ligatures":
            if let v = parseLigatures(val) { c.ligatures = v }
        case "font-feature":
            c.fontFeature = val
        case "adjust-cell-width":
            if let n = Int(val) { c.adjustCellWidth = n }
        case "adjust-cell-height":
            if let n = Int(val) { c.adjustCellHeight = n }
        case "background-opacity":
            if let n = Double(val) { c.backgroundOpacity = CGFloat(min(1, max(0, n))) }
        case "background":
            if val.isEmpty { c.background = nil }
            else if let rgb = parseColor(val) { c.background = rgb }
        case "foreground":
            if val.isEmpty { c.foreground = nil }
            else if let rgb = parseColor(val) { c.foreground = rgb }
        case "cursor-color":
            let v = unquote(val)
            if v.isEmpty || v.lowercased() == "cell-foreground" {
                c.cursorColor = nil
            } else if let rgb = parseColor(v) {
                c.cursorColor = rgb
            }
        case "cursor-style":
            if val.isEmpty { c.cursorStyle = .block }
            else if let v = parseCursorStyle(val) { c.cursorStyle = v }
        case "cursor-style-blink":
            if val.isEmpty { c.cursorStyleBlink = false }
            else if let v = parseCursorBlink(val) { c.cursorStyleBlink = v }
        case "palette":
            if val.isEmpty {
                c.paletteOverlay = Array(repeating: 0, count: 16)
                c.paletteOverlayMask = 0
            } else {
                applyPaletteEntry(val, into: &c)
            }
        case "link-url":
            c.linkURL = parseBool(val)
        case "desktop-notifications":
            c.desktopNotifications = parseBool(val)
        case "progress-style":
            c.progressStyle = parseBool(val)
        case "macos-auto-secure-input":
            c.macosAutoSecureInput = parseBool(val)
        case "macos-applescript":
            c.macosAppleScript = parseBool(val)
        case "macos-option-as-alt":
            if val.isEmpty { c.macosOptionAsAlt = .unset }
            else if let v = parseOptionAsAlt(val) { c.macosOptionAsAlt = v }
        case "window-padding-x":
            if val.isEmpty {
                c.windowPaddingLeft = defaultPadPt
                c.windowPaddingRight = defaultPadPt
            } else if let pair = parsePadPair(val) {
                c.windowPaddingLeft = pair.0
                c.windowPaddingRight = pair.1
            }
        case "window-padding-y":
            if val.isEmpty {
                c.windowPaddingTop = defaultPadPt
                c.windowPaddingBottom = defaultPadPt
            } else if let pair = parsePadPair(val) {
                c.windowPaddingTop = pair.0
                c.windowPaddingBottom = pair.1
            }
        case "window-width":
            if val.isEmpty { c.windowWidth = nil }
            else if let n = Int(val.trimmingCharacters(in: .whitespaces)) { c.windowWidth = n }
        case "window-height":
            if val.isEmpty { c.windowHeight = nil }
            else if let n = Int(val.trimmingCharacters(in: .whitespaces)) { c.windowHeight = n }
        case "scrollback-lines":
            if let n = Int(val), n >= 0 { c.scrollbackLines = n }
        case "copy-on-select":
            c.copyOnSelect = parseBool(val)
        case "command":
            let v = unquote(val)
            c.command = v.isEmpty ? nil : v
        case "working-directory":
            c.workingDirectory = parseWorkingDirectory(val)
        case "env":
            applyEnvEntry(val, into: &c)
        case "clipboard-paste-protection":
            if val.isEmpty { c.clipboardPasteProtection = true }
            else if let v = parseTrueFalse(val) { c.clipboardPasteProtection = v }
        case "confirm-close-surface":
            if val.isEmpty { c.confirmCloseSurface = .on }
            else if let v = parseConfirmClose(val) { c.confirmCloseSurface = v }
        case "osc52-write":
            c.osc52Write = val == "deny" ? .deny : .allow
        case "osc52-read":
            c.osc52Read = val == "deny" ? .deny : .ask
        case "keybind":
            if val == "clear" {
                c.keybinds.removeAll()
            } else if !val.isEmpty {
                c.keybinds.append(val)
            }
        case "kitty-graphics":
            c.kittyGraphics = parseOnOff(val)
        case "shell-integration":
            if let v = parseShellIntegration(val) { c.shellIntegration = v }
        case "notify-on-command-finish":
            if let v = parseNotifyWhen(val) { c.notifyOnCommandFinish = v }
        case "notify-on-command-finish-after":
            if let n = parseSeconds(val) { c.notifyOnCommandFinishAfter = n }
        case "notify-on-command-finish-action":
            parseNotifyAction(val, into: &c)
        default:
            if key.hasPrefix("palette-"),
               let idx = Int(key.dropFirst("palette-".count)),
               (0...15).contains(idx)
            {
                if val.isEmpty {
                    c.paletteOverlayMask &= ~UInt16(1 << idx)
                } else if let rgb = parseColor(val) {
                    c.paletteOverlay[idx] = rgb
                    c.paletteOverlayMask |= UInt16(1 << idx)
                }
            }
        }
    }

    /// `palette = N=COLOR`. Indices 16–255 are ignored (0–15 overlay only).
    static func applyPaletteEntry(_ raw: String, into c: inout AppConfig) {
        guard let eq = raw.firstIndex(of: "=") else { return }
        let idxRaw = raw[..<eq].trimmingCharacters(in: .whitespaces)
        let colorRaw = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let idx = parsePaletteIndex(idxRaw), (0...15).contains(idx),
              let rgb = parseColor(colorRaw)
        else { return }
        c.paletteOverlay[idx] = rgb
        c.paletteOverlayMask |= UInt16(1 << idx)
    }

    static func parsePaletteIndex(_ raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("0b") || t.hasPrefix("0B") { return Int(t.dropFirst(2), radix: 2) }
        if t.hasPrefix("0o") || t.hasPrefix("0O") { return Int(t.dropFirst(2), radix: 8) }
        return Int(t)
    }

    static func isHex(_ u: UnicodeScalar) -> Bool {
        (u >= "0" && u <= "9") || (u >= "a" && u <= "f") || (u >= "A" && u <= "F")
    }

    static let x11Color: [String: UInt32] = [
        "black": 0x000000,
        "white": 0xFFFFFF,
        "red": 0xFF0000,
        "green": 0x00FF00,
        "blue": 0x0000FF,
        "yellow": 0xFFFF00,
        "cyan": 0x00FFFF,
        "magenta": 0xFF00FF,
        "gray": 0xBEBEBE,
        "grey": 0xBEBEBE,
        "orange": 0xFFA500,
        "purple": 0xA020F0,
    ]
}
