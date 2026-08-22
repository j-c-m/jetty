import Foundation

public enum Dec2026 {
    public static let timeoutNs: UInt64 = 1_000_000_000

    /// True while synchronized output holds the GPU present.
    public static func skipPresent(sync: Bool, holdStart: UInt64, now: UInt64) -> Bool {
        guard sync else { return false }
        if holdStart == 0 { return true }
        return now &- holdStart < timeoutNs
    }
}
