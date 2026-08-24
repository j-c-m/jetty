import Foundation

public enum Dec2026 {
    public static let timeoutNs: UInt64 = 1_000_000_000

    /// True while synchronized output holds the GPU present.
    /// `flush` is set on `2026l` so a following `2026h` still presents that frame.
    public static func skipPresent(
        sync: Bool,
        flush: Bool,
        holdStart: UInt64,
        now: UInt64
    ) -> Bool {
        if flush { return false }
        guard sync else { return false }
        if holdStart == 0 { return true }
        return now &- holdStart < timeoutNs
    }
}
