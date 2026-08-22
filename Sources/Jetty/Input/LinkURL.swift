import Foundation

public enum LinkURL {
    public static func openable(_ string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        for u in string.unicodeScalars {
            if u.value < 0x20 || (u.value >= 0x7F && u.value < 0xA0) { return nil }
            if u.value >= 0x202A && u.value <= 0x2069 { return nil }
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return nil
        }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !c.path.isEmpty
            else { return nil }
            return url
        default:
            return nil
        }
    }
}
