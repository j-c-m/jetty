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

        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            return [0x0D]
        }
        if event.keyCode == UInt16(kVK_Delete) { return [0x08] }
        if event.keyCode == UInt16(kVK_Escape) { return [0x1B] }

        if !flags.contains(.option), let text = event.characters, !text.isEmpty {
            return Array(text.utf8)
        }
        return nil
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
