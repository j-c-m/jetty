import Foundation

public struct AppConfig: Sendable {
    public var fontFamily: String? = nil
    public var fontSize: CGFloat = 20
    public var ligatures: Ligatures = .programming
    public var fontFeature: String = ""
    public var adjustCellWidth: Int = 0
    public var adjustCellHeight: Int = 0
    public var backgroundOpacity: CGFloat = 1
    public var paletteOverlay: [UInt32] = Array(repeating: 0, count: 16)
    public var paletteOverlayMask: UInt16 = 0
    public var linkURL: Bool = true
    public var desktopNotifications: Bool = true
    public var progressStyle: Bool = true
    public var macosAutoSecureInput: Bool = true
    public var macosAppleScript: Bool = true
    public var scrollbackLines: Int = 50_000
    public var copyOnSelect: Bool = true
    public var launchCols: Int = 105
    public var launchRows: Int = 35
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

    public static func load() -> AppConfig {
        let url = configURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return AppConfig() }
        return parse(text)
    }

    public static func parse(_ text: String) -> AppConfig {
        var c = AppConfig()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = parts[1]
            switch key {
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
            case "scrollback-lines":
                if let n = Int(val), n >= 0 { c.scrollbackLines = n }
            case "copy-on-select":
                c.copyOnSelect = parseBool(val)
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
                   (0...15).contains(idx),
                   let rgb = parseHexRGB(val)
                {
                    c.paletteOverlay[idx] = rgb
                    c.paletteOverlayMask |= UInt16(1 << idx)
                }
            }
        }
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

    /// Ghostty `Duration`: `1h30m`, `45s`, `500ms`. A bare number is seconds.
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
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }
}
