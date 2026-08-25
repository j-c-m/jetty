import CVt
import Foundation

public enum Dec2026 {
    public static let timeoutNs: UInt64 = 1_000_000_000

    /// True while synchronized output holds the GPU present.
    /// `flush` is set on `2026l` so a following `2026h` still presents that
    /// frame, unless the grid mutated after `2026h`.
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

    /// Draw skip peek. Must not take the session lock.
    public static func peekSkip(
        _ scr: UnsafeMutablePointer<jt_scr>,
        holdStart: UInt64,
        now: UInt64
    ) -> Bool {
        skipPresent(
            sync: jt_sync_on(scr) != 0,
            flush: jt_sync_flush(scr) != 0,
            holdStart: holdStart,
            now: now
        )
    }

    public static func holdGen(_ scr: UnsafeMutablePointer<jt_scr>) -> UInt32 {
        jt_sync_hold_gen(scr)
    }
}
