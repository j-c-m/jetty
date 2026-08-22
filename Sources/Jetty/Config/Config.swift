import Foundation

public struct AppConfig: Sendable {
    public var fontSize: CGFloat = 20
    public var scrollbackLines: Int = 50_000
    public var copyOnSelect: Bool = true
    public var launchCols: Int = 105
    public var launchRows: Int = 35

    public static func load() -> AppConfig {
        var c = AppConfig()
        let url = configURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return c }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "font-size":
                if let n = Double(parts[1]) { c.fontSize = CGFloat(min(72, max(8, n))) }
            case "scrollback-lines":
                if let n = Int(parts[1]), n >= 0 { c.scrollbackLines = n }
            case "copy-on-select":
                c.copyOnSelect = ["true", "1", "yes"].contains(parts[1].lowercased())
            default:
                break
            }
        }
        return c
    }

    public static func configURL() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() + "/.config")
        return URL(fileURLWithPath: base).appendingPathComponent("jetty/config")
    }
}
