import AppKit
import Carbon.HIToolbox

public enum XtermKeyEncoder {
    public static func bytes(for event: NSEvent, applicationCursor: Bool) -> [UInt8]? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }

        if flags.contains(.control), let c0 = classicControlByte(for: event) {
            return [c0]
        }

        if event.keyCode == UInt16(kVK_Tab) {
            if flags.contains(.shift) { return [0x1B, 0x5B, 0x5A] }
            return [0x09]
        }

        if let seq = special(event.keyCode, flags: flags, applicationCursor: applicationCursor) {
            return seq
        }

        if flags.contains(.option),
           let raw = event.charactersIgnoringModifiers, let ch = raw.unicodeScalars.first,
           ch.isASCII, ch.value >= 0x20, ch.value < 0x7F {
            return [0x1B, UInt8(ch.value)]
        }

        if isReturn(event.keyCode) {
            if flags.contains(.shift) { return [0x0A] }
            return [0x0D]
        }
        if event.keyCode == UInt16(kVK_Delete) { return [0x08] }
        if event.keyCode == UInt16(kVK_Escape) { return [0x1B] }

        if !flags.contains(.option), let text = event.characters, !text.isEmpty {
            return Array(text.utf8)
        }
        return nil
    }

    /// Encode an AppleScript / Ghostty `send key` name. `command` is not representable.
    public static func bytes(
        named raw: String,
        shift: Bool,
        option: Bool,
        control: Bool,
        applicationCursor: Bool
    ) -> [UInt8]? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if key.lowercased() == "insert" {
            return [0x1B, 0x5B, 0x32, 0x7E]
        }
        guard let parts = namedParts(key, shift: shift) else { return nil }
        var flags = NSEvent.ModifierFlags()
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: parts.chars,
            charactersIgnoringModifiers: parts.ignoring,
            isARepeat: false,
            keyCode: parts.keyCode
        ) else { return nil }
        return bytes(for: event, applicationCursor: applicationCursor)
    }

    private static func namedParts(_ raw: String, shift: Bool) -> (keyCode: UInt16, chars: String, ignoring: String)? {
        let key = raw.lowercased()
        switch key {
        case "enter", "return":
            return (UInt16(kVK_Return), "\r", "\r")
        case "escape", "esc":
            return (UInt16(kVK_Escape), "\u{1B}", "\u{1B}")
        case "tab":
            return (UInt16(kVK_Tab), "\t", "\t")
        case "space":
            return (UInt16(kVK_Space), " ", " ")
        case "backspace":
            return (UInt16(kVK_Delete), "\u{08}", "\u{08}")
        case "delete":
            return (UInt16(kVK_ForwardDelete), "", "")
        case "up", "arrowup":
            return (UInt16(kVK_UpArrow), "", "")
        case "down", "arrowdown":
            return (UInt16(kVK_DownArrow), "", "")
        case "left", "arrowleft":
            return (UInt16(kVK_LeftArrow), "", "")
        case "right", "arrowright":
            return (UInt16(kVK_RightArrow), "", "")
        case "home":
            return (UInt16(kVK_Home), "", "")
        case "end":
            return (UInt16(kVK_End), "", "")
        case "pageup":
            return (UInt16(kVK_PageUp), "", "")
        case "pagedown":
            return (UInt16(kVK_PageDown), "", "")
        case "f1": return (UInt16(kVK_F1), "", "")
        case "f2": return (UInt16(kVK_F2), "", "")
        case "f3": return (UInt16(kVK_F3), "", "")
        case "f4": return (UInt16(kVK_F4), "", "")
        case "f5": return (UInt16(kVK_F5), "", "")
        case "f6": return (UInt16(kVK_F6), "", "")
        case "f7": return (UInt16(kVK_F7), "", "")
        case "f8": return (UInt16(kVK_F8), "", "")
        case "f9": return (UInt16(kVK_F9), "", "")
        case "f10": return (UInt16(kVK_F10), "", "")
        case "f11": return (UInt16(kVK_F11), "", "")
        case "f12": return (UInt16(kVK_F12), "", "")
        case "digit0": return namedParts("0", shift: shift)
        case "digit1": return namedParts("1", shift: shift)
        case "digit2": return namedParts("2", shift: shift)
        case "digit3": return namedParts("3", shift: shift)
        case "digit4": return namedParts("4", shift: shift)
        case "digit5": return namedParts("5", shift: shift)
        case "digit6": return namedParts("6", shift: shift)
        case "digit7": return namedParts("7", shift: shift)
        case "digit8": return namedParts("8", shift: shift)
        case "digit9": return namedParts("9", shift: shift)
        default:
            break
        }
        guard key.utf8.count == 1, let ch = key.unicodeScalars.first, ch.isASCII,
              ch.value >= 0x20, ch.value < 0x7F
        else { return nil }
        let ignoring = String(ch)
        let chars: String
        if ch.value >= 0x61, ch.value <= 0x7A, shift {
            chars = ignoring.uppercased()
        } else {
            chars = ignoring
        }
        return (ansiKeyCode(ch.value) ?? 0, chars, ignoring)
    }

    private static func ansiKeyCode(_ ascii: UInt32) -> UInt16? {
        switch ascii {
        case 0x61: return UInt16(kVK_ANSI_A)
        case 0x62: return UInt16(kVK_ANSI_B)
        case 0x63: return UInt16(kVK_ANSI_C)
        case 0x64: return UInt16(kVK_ANSI_D)
        case 0x65: return UInt16(kVK_ANSI_E)
        case 0x66: return UInt16(kVK_ANSI_F)
        case 0x67: return UInt16(kVK_ANSI_G)
        case 0x68: return UInt16(kVK_ANSI_H)
        case 0x69: return UInt16(kVK_ANSI_I)
        case 0x6A: return UInt16(kVK_ANSI_J)
        case 0x6B: return UInt16(kVK_ANSI_K)
        case 0x6C: return UInt16(kVK_ANSI_L)
        case 0x6D: return UInt16(kVK_ANSI_M)
        case 0x6E: return UInt16(kVK_ANSI_N)
        case 0x6F: return UInt16(kVK_ANSI_O)
        case 0x70: return UInt16(kVK_ANSI_P)
        case 0x71: return UInt16(kVK_ANSI_Q)
        case 0x72: return UInt16(kVK_ANSI_R)
        case 0x73: return UInt16(kVK_ANSI_S)
        case 0x74: return UInt16(kVK_ANSI_T)
        case 0x75: return UInt16(kVK_ANSI_U)
        case 0x76: return UInt16(kVK_ANSI_V)
        case 0x77: return UInt16(kVK_ANSI_W)
        case 0x78: return UInt16(kVK_ANSI_X)
        case 0x79: return UInt16(kVK_ANSI_Y)
        case 0x7A: return UInt16(kVK_ANSI_Z)
        case 0x30: return UInt16(kVK_ANSI_0)
        case 0x31: return UInt16(kVK_ANSI_1)
        case 0x32: return UInt16(kVK_ANSI_2)
        case 0x33: return UInt16(kVK_ANSI_3)
        case 0x34: return UInt16(kVK_ANSI_4)
        case 0x35: return UInt16(kVK_ANSI_5)
        case 0x36: return UInt16(kVK_ANSI_6)
        case 0x37: return UInt16(kVK_ANSI_7)
        case 0x38: return UInt16(kVK_ANSI_8)
        case 0x39: return UInt16(kVK_ANSI_9)
        default: return nil
        }
    }

    /// `interpretKeyEvents` owns the key while composing or after insertText.
    public static func shouldEncodeKeyDown(
        hasMarkedText: Bool,
        wasMarked: Bool,
        insertTextConsumed: Bool
    ) -> Bool {
        !hasMarkedText && !wasMarked && !insertTextConsumed
    }

    /// Option-as-meta and Shift+Enter when IME is idle. insertText must not eat those keys.
    public static func insertTextDefersToEncoder(composing: Bool, event: NSEvent?) -> Bool {
        guard !composing, let event, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        if flags.contains(.option) { return true }
        if flags.contains(.shift), isReturn(event.keyCode) { return true }
        return false
    }

    static func isReturn(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    /// Committed IME / insertText. LF → CR. While composing, ignore empty and C0-only.
    public static func committedUTF8(_ text: String, composing: Bool) -> [UInt8]? {
        if text.isEmpty { return nil }
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count)
        var onlyC0 = true
        for b in text.utf8 {
            let mapped: UInt8 = b == 0x0A ? 0x0D : b
            if mapped >= 0x20, mapped != 0x7F { onlyC0 = false }
            out.append(mapped)
        }
        if composing, onlyC0 { return nil }
        return out
    }

    /// DECSET 1007: accumulated wheel rows (+up) to CSI/SS3 cursor keys.
    public static func alternateScroll(
        deltaRows: Double,
        pending: inout Double,
        applicationCursor: Bool
    ) -> [UInt8]? {
        pending += deltaRows
        let n = Int(pending.rounded(.towardZero))
        if n == 0 { return nil }
        pending -= Double(n)
        let count = min(abs(n), 256)
        let letter: UInt8 = n > 0 ? 0x41 : 0x42
        let one: [UInt8] = applicationCursor
            ? [0x1B, 0x4F, letter]
            : [0x1B, 0x5B, letter]
        var out = [UInt8]()
        out.reserveCapacity(one.count * count)
        for _ in 0..<count { out.append(contentsOf: one) }
        return out
    }

    private static func special(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, applicationCursor: Bool) -> [UInt8]? {
        let shift = flags.contains(.shift)
        let alt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let mod = (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        func arrow(_ letter: UInt8) -> [UInt8] {
            if mod == 0 {
                return applicationCursor ? [0x1B, 0x4F, letter] : [0x1B, 0x5B, letter]
            }
            return [0x1B, 0x5B, 0x31, 0x3B, UInt8(ascii: "1") &+ UInt8(mod), letter]
        }
        switch Int(keyCode) {
        case kVK_UpArrow: return arrow(0x41)
        case kVK_DownArrow: return arrow(0x42)
        case kVK_RightArrow: return arrow(0x43)
        case kVK_LeftArrow: return arrow(0x44)
        case kVK_Home:
            return applicationCursor && mod == 0 ? [0x1B, 0x4F, 0x48] : [0x1B, 0x5B, 0x48]
        case kVK_End:
            return applicationCursor && mod == 0 ? [0x1B, 0x4F, 0x46] : [0x1B, 0x5B, 0x46]
        case kVK_PageUp: return [0x1B, 0x5B, 0x35, 0x7E]
        case kVK_PageDown: return [0x1B, 0x5B, 0x36, 0x7E]
        case kVK_ForwardDelete: return [0x1B, 0x5B, 0x33, 0x7E]
        case kVK_F1: return [0x1B, 0x4F, 0x50]
        case kVK_F2: return [0x1B, 0x4F, 0x51]
        case kVK_F3: return [0x1B, 0x4F, 0x52]
        case kVK_F4: return [0x1B, 0x4F, 0x53]
        case kVK_F5: return [0x1B, 0x5B, 0x31, 0x35, 0x7E]
        case kVK_F6: return [0x1B, 0x5B, 0x31, 0x37, 0x7E]
        case kVK_F7: return [0x1B, 0x5B, 0x31, 0x38, 0x7E]
        case kVK_F8: return [0x1B, 0x5B, 0x31, 0x39, 0x7E]
        case kVK_F9: return [0x1B, 0x5B, 0x32, 0x30, 0x7E]
        case kVK_F10: return [0x1B, 0x5B, 0x32, 0x31, 0x7E]
        case kVK_F11: return [0x1B, 0x5B, 0x32, 0x33, 0x7E]
        case kVK_F12: return [0x1B, 0x5B, 0x32, 0x34, 0x7E]
        default:
            _ = shift
            return nil
        }
    }

    public static func classicControlByte(for event: NSEvent) -> UInt8? {
        if let chars = event.characters, chars.count == 1, let u = chars.unicodeScalars.first {
            let v = u.value
            if v < 0x20 { return UInt8(v) }
        }
        guard let raw = event.charactersIgnoringModifiers, let ch = raw.first else { return nil }
        if let ascii = ch.asciiValue {
            let lower = ascii | 0x20
            if lower >= UInt8(ascii: "a"), lower <= UInt8(ascii: "z") {
                return lower &- UInt8(ascii: "a") &+ 1
            }
        }
        switch ch {
        case " ", "@", "2": return 0x00
        case "[", "3": return 0x1B
        case "\\", "4": return 0x1C
        case "]", "5": return 0x1D
        case "^", "6": return 0x1E
        case "_", "-", "7": return 0x1F
        case "?": return 0x7F
        default: return nil
        }
    }
}
