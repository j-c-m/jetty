/// Host-side filter and encode for xterm mouse tracking.
public enum MouseReport {
    public enum Action {
        case press, release, motion
    }

    /// X10 9: press L/M/R only. 1000: press+release. 1002: + motion while down. 1003: all motion.
    public static func shouldReport(mode: UInt16, action: Action, button: UInt8?) -> Bool {
        switch mode {
        case 9:
            return action == .press && (button == 0 || button == 1 || button == 2)
        case 1000:
            return action != .motion
        case 1002:
            return button != nil
        case 1003:
            return true
        default:
            return false
        }
    }

    public static func packet(
        mode: UInt16,
        sgr: Bool,
        action: Action,
        button: UInt8?,
        x: Int,
        y: Int,
        shift: Bool = false,
        meta: Bool = false,
        ctrl: Bool = false
    ) -> [UInt8]? {
        guard shouldReport(mode: mode, action: action, button: button) else { return nil }
        if sgr {
            let btn = button ?? 3
            return SGRMouse.packet(
                button: btn,
                x: x,
                y: y,
                motion: action == .motion,
                release: action == .release,
                shift: shift,
                meta: meta,
                ctrl: ctrl
            )
        }
        var x10btn: UInt8
        if action == .release {
            x10btn = 3
        } else if action == .motion {
            x10btn = 32 &+ (button ?? 3)
        } else {
            x10btn = button ?? 0
        }
        let mods = mode != 9
        return X10Mouse.packet(
            button: x10btn,
            x: x,
            y: y,
            shift: mods && shift,
            meta: mods && meta,
            ctrl: mods && ctrl
        )
    }
}
