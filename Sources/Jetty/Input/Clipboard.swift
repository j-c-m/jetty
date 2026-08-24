import AppKit

public enum Clipboard {
    public static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    public static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// Encode a host paste. When 2004 is on, wrap `ESC [ 200 ~` … `ESC [ 201 ~`
    /// and drop any nested end sequence from the payload.
    public static func pasteBytes(_ data: [UInt8], bracketed: Bool) -> [UInt8] {
        guard bracketed else { return data }
        var out: [UInt8] = []
        out.reserveCapacity(data.count + pasteStart.count + pasteEnd.count)
        out.append(contentsOf: pasteStart)
        var i = 0
        while i < data.count {
            if data[i...].starts(with: pasteEnd) {
                i += pasteEnd.count
                continue
            }
            out.append(data[i])
            i += 1
        }
        out.append(contentsOf: pasteEnd)
        return out
    }

    public static func focusBytes(gained: Bool) -> [UInt8] {
        gained ? [0x1B, 0x5B, 0x49] : [0x1B, 0x5B, 0x4F]
    }

    /// POSIX single-quote. `'` inside the path becomes `'\''`.
    public static func posixQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote paths and join with spaces for a drop onto the PTY.
    public static func droppedPaths(_ paths: [String]) -> String {
        paths.map(posixQuote).joined(separator: " ")
    }

    /// File URLs, then a clipboard image as a temp PNG, then plain string.
    public static func pasteboardPayload(_ pb: NSPasteboard = .general) -> String? {
        let files = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        if let files, !files.isEmpty {
            return droppedPaths(files.map(\.path))
        }
        if let path = writeImage(from: pb) {
            return posixQuote(path)
        }
        if let str = pb.string(forType: .string), !str.isEmpty {
            return str
        }
        return nil
    }

    static func pngFromTIFF(_ tiff: Data) -> Data? {
        guard let img = NSImage(data: tiff),
              let tiffRep = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffRep)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func writeImage(from pb: NSPasteboard) -> String? {
        let png: Data?
        if let d = pb.data(forType: .png) {
            png = d
        } else if let tiff = pb.data(forType: .tiff) {
            png = pngFromTIFF(tiff)
        } else {
            return nil
        }
        guard let png else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetty-paste-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url.path
    }
}
