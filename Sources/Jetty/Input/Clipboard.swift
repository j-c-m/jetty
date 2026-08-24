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
}
