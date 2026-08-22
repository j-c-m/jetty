/// SGR 1006: `CSI < Pb ; Px ; Py M` press/motion, `m` release.
public enum SGRMouse {
    /// `button`: 0 left, 1 middle, 2 right, 64 wheel-up, 65 wheel-down. Motion adds 32.
    public static func packet(
        button: UInt8,
        x: Int,
        y: Int,
        motion: Bool = false,
        release: Bool = false,
        shift: Bool = false,
        meta: Bool = false,
        ctrl: Bool = false
    ) -> [UInt8] {
        var pb = button
        if motion { pb &+= 32 }
        if shift { pb &+= 4 }
        if meta { pb &+= 8 }
        if ctrl { pb &+= 16 }
        let px = max(1, x)
        let py = max(1, y)
        var out: [UInt8] = [0x1B, 0x5B, 0x3C]
        out.append(contentsOf: Array(String(pb).utf8))
        out.append(0x3B)
        out.append(contentsOf: Array(String(px).utf8))
        out.append(0x3B)
        out.append(contentsOf: Array(String(py).utf8))
        out.append(release ? 0x6D : 0x4D)
        return out
    }
}
