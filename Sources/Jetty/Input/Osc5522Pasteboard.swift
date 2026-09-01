import AppKit
import Foundation

public enum Osc5522Pasteboard {
    public static func normalizeMime(_ raw: String) -> String {
        let head = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return isTypeSubtype(lower) ? lower : trimmed
    }

    /// NSPasteboardItem requires a UTI. Known MIME uses AppKit types; others use a Jetty UTI.
    static func pasteboardType(forMime mime: String) -> NSPasteboard.PasteboardType {
        switch mime {
        case "text/plain": return .string
        case "text/html": return .html
        case "text/rtf": return .rtf
        case "text/rtfd": return .rtfd
        case "image/png": return .png
        case "image/tiff": return .tiff
        case "image/jpeg": return jpegType
        case "application/pdf": return .pdf
        default:
            return customType(forMime: mime)
        }
    }

    /// Declared pasteboard types only. Never `data(forType:)` / `string(forType:)` / `readObjects`.
    public static func available(_ pb: NSPasteboard) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for type in pb.types ?? [] {
            for mime in inferredMimes(for: type) {
                if seen.insert(mime).inserted {
                    out.append(mime)
                    if out.count == Osc5522.maxListingMimes { return out }
                }
            }
        }
        return out
    }

    public static func write(_ pb: NSPasteboard, contents: [(mime: String, data: Data)]) -> Bool {
        pb.clearContents()
        var nonFile: [(mime: String, data: Data)] = []
        var uriData: Data?
        for item in contents {
            if normalizeMime(item.mime) == "text/uri-list" {
                uriData = item.data
            } else {
                nonFile.append(item)
            }
        }
        let body: Data?
        let fileURLs: [URL]
        if let uriData {
            if let s = String(data: uriData, encoding: .utf8) {
                let normalized = uriListBody(s)
                body = normalized.isEmpty ? nil : normalized
                fileURLs = parseFileURLs(s)
            } else {
                body = uriData
                fileURLs = []
            }
        } else {
            body = nil
            fileURLs = []
        }
        if fileURLs.isEmpty && nonFile.isEmpty && body == nil {
            return true
        }
        if fileURLs.isEmpty {
            let item = NSPasteboardItem()
            stampNonFile(item, contents: nonFile)
            if let body {
                item.setData(body, forType: pasteboardType(forMime: "text/uri-list"))
            }
            return pb.writeObjects([item])
        }
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(fileURLs.count)
        for (i, url) in fileURLs.enumerated() {
            let item = NSPasteboardItem()
            if i == 0 {
                stampNonFile(item, contents: nonFile)
                if let body {
                    item.setData(body, forType: pasteboardType(forMime: "text/uri-list"))
                }
                item.setPropertyList(fileURLs.map(\.path), forType: filenamesType)
            }
            item.setString(url.absoluteString, forType: .fileURL)
            items.append(item)
        }
        return pb.writeObjects(items)
    }
}

extension Osc5522Pasteboard {
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let customUTIPrefix = "dev.jetty.mime."
    /// UTI-legal stand-in for NSFilenamesPboardType on NSPasteboardItem.
    private static let filenamesType = NSPasteboard.PasteboardType("dev.jetty.filenames")

    private static func isTypeSubtype(_ mime: String) -> Bool {
        let parts = mime.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return !mime.contains(where: \.isWhitespace)
    }

    private static func customType(forMime mime: String) -> NSPasteboard.PasteboardType {
        let hex = mime.utf8.map { String(format: "%02x", $0) }.joined()
        return NSPasteboard.PasteboardType(customUTIPrefix + hex)
    }

    private static func mime(fromCustomType raw: String) -> String? {
        guard raw.hasPrefix(customUTIPrefix) else { return nil }
        let hex = raw.dropFirst(customUTIPrefix.count)
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func inferredMimes(for type: NSPasteboard.PasteboardType) -> [String] {
        switch type.rawValue {
        case NSPasteboard.PasteboardType.string.rawValue,
             "public.utf8-plain-text",
             "public.utf16-plain-text",
             "NSStringPboardType",
             "com.apple.traditional-mac-plain-text":
            return ["text/plain"]
        case NSPasteboard.PasteboardType.html.rawValue, "public.html":
            return ["text/html"]
        case NSPasteboard.PasteboardType.rtf.rawValue, "public.rtf":
            return ["text/rtf"]
        case NSPasteboard.PasteboardType.rtfd.rawValue, "com.apple.flat-rtfd":
            return ["text/rtfd"]
        case NSPasteboard.PasteboardType.png.rawValue, "public.png":
            return ["image/png"]
        case NSPasteboard.PasteboardType.tiff.rawValue, "public.tiff":
            return ["image/tiff", "image/png"]
        case "public.jpeg":
            return ["image/jpeg"]
        case NSPasteboard.PasteboardType.pdf.rawValue, "com.adobe.pdf":
            return ["application/pdf"]
        case NSPasteboard.PasteboardType.fileURL.rawValue, "public.file-url", "NSFilenamesPboardType":
            return ["text/uri-list", "text/plain"]
        default:
            if let custom = mime(fromCustomType: type.rawValue) {
                let n = normalizeMime(custom)
                if isTypeSubtype(n) { return [n] }
                return []
            }
            let mime = normalizeMime(type.rawValue)
            return isTypeSubtype(mime) ? [mime] : []
        }
    }

    private static func stampNonFile(_ item: NSPasteboardItem, contents: [(mime: String, data: Data)]) {
        for (rawMime, data) in contents {
            let mime = normalizeMime(rawMime)
            if mime == "text/uri-list" { continue }
            switch mime {
            case "text/plain":
                if let s = String(data: data, encoding: .utf8) {
                    item.setString(s, forType: .string)
                } else {
                    item.setData(data, forType: .string)
                }
            case "text/html":
                item.setData(data, forType: .html)
            case "text/rtf":
                item.setData(data, forType: .rtf)
            case "text/rtfd":
                item.setData(data, forType: .rtfd)
            case "image/png":
                item.setData(data, forType: .png)
            case "image/tiff":
                item.setData(data, forType: .tiff)
            case "image/jpeg":
                item.setData(data, forType: jpegType)
            case "application/pdf":
                item.setData(data, forType: .pdf)
            default:
                item.setData(data, forType: pasteboardType(forMime: mime))
            }
        }
    }

    private static func splitUriListLines(_ s: String) -> [String] {
        let normalized = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func uriListBody(_ s: String) -> Data {
        let lines = splitUriListLines(s)
        if lines.isEmpty { return Data() }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func parseFileURLs(_ s: String) -> [URL] {
        var urls: [URL] = []
        for line in splitUriListLines(s) {
            guard let url = URL(string: line), url.isFileURL else { continue }
            urls.append(url)
        }
        return urls
    }
}
