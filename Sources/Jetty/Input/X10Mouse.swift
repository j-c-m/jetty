/// X10 `kmous=\E[M` report: `ESC [ M Cb Cx Cy`.
public enum X10Mouse {
    /// `button`: 0 left, 1 middle, 2 right, 3 release, 32+btn motion, 64 wheel-up, 65 wheel-down.
    public static func packet(
        button: UInt8,
        x: Int,
        y: Int,
        shift: Bool = false,
        meta: Bool = false,
        ctrl: Bool = false
    ) -> [UInt8] {
        var cb: UInt8 = 32 &+ button
        if shift { cb &+= 4 }
        if meta { cb &+= 8 }
        if ctrl { cb &+= 16 }
        let cx = UInt8(min(223, max(1, x)) &+ 32)
        let cy = UInt8(min(223, max(1, y)) &+ 32)
        return [0x1B, 0x5B, 0x4D, cb, cx, cy]
    }
}
