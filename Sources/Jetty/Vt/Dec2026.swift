import CVt
import Foundation

public enum Dec2026 {
    public static let timeoutNs: UInt64 = 1_000_000_000

    /// Skip GPU presents while `2026h` holds, unless an ESU freeze is
    /// ready. Timeout forces a present so a stuck hold cannot freeze the GPU.
    public static func skipPresent(
        sync: Bool,
        holdStart: UInt64,
        now: UInt64,
        snap: Bool = false
    ) -> Bool {
        if snap { return false }
        guard sync else { return false }
        if holdStart == 0 { return true }
        return now &- holdStart < timeoutNs
    }

    /// Draw skip peek. Must not take the session lock.
    public static func peekSkip(
        _ scr: UnsafeMutablePointer<jt_scr>,
        holdStart: UInt64,
        now: UInt64
    ) -> Bool {
        skipPresent(
            sync: jt_sync_on(scr) != 0,
            holdStart: holdStart,
            now: now,
            snap: jt_sync_snap_valid(scr) != 0
        )
    }

    public static func holdGen(_ scr: UnsafeMutablePointer<jt_scr>) -> UInt32 {
        jt_sync_hold_gen(scr)
    }
}
