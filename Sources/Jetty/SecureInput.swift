import Carbon
import CPty
import Foundation

/// Process-wide `EnableSecureEventInput`.
@MainActor
public enum SecureInput {
    private static var held = false
    private static var manual = false
    private static var suppressAuto = false
    private static var autoEnabled = true
    private static var password = false
    private static var appActive = true

    public static var isOn: Bool { held }
    public static var isManual: Bool { manual }

    public static func setAutoEnabled(_ on: Bool) {
        autoEnabled = on
        if !on { suppressAuto = false }
        apply()
    }

    public static func setAppActive(_ on: Bool) {
        appActive = on
        apply()
    }

    public static func setPasswordPrompt(_ on: Bool) {
        if !on { suppressAuto = false }
        password = on
        apply()
    }

    /// Menu / `toggle_secure_input`. Off while held also suppresses auto until echo returns.
    public static func toggle() {
        if held {
            manual = false
            suppressAuto = true
        } else {
            manual = true
            suppressAuto = false
        }
        apply()
    }

    public static func shutdown() {
        manual = false
        password = false
        suppressAuto = false
        apply()
    }

    nonisolated public static func passwordPrompt(fd: Int32) -> Bool {
        jt_pty_password_prompt(fd) == 1
    }

    private static func apply() {
        let autoOn = autoEnabled && password && !suppressAuto
        let want = appActive && (manual || autoOn)
        if want, !held {
            _ = EnableSecureEventInput()
            held = true
        } else if !want, held {
            _ = DisableSecureEventInput()
            held = false
        }
    }
}
