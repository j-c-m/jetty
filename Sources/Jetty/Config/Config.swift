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

    public static func parseBool(_ s: String) -> Bool {
        ["true", "1", "yes"].contains(s.lowercased())
    }

    public static func parseLigatures(_ s: String) -> Ligatures? {
        switch s.lowercased() {
        case "off", "false", "0", "no": return .off
        case "programming": return .programming
        case "on", "true", "1", "yes": return .on
        default: return nil
        }
    }

    public static func parseHexRGB(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }
}
