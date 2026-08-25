import AppKit
import Carbon.HIToolbox

/// Host-only `keybind = trigger=action` table. Unknown lines are ignored.
public struct Keybinds: Sendable {
    public enum Action: Equatable, Sendable {
        case copy, paste, selectAll
        case newWindow, closeWindow
        case increaseFontSize, decreaseFontSize, resetFontSize
        case scrollToTop, scrollToBottom, scrollPageUp, scrollPageDown
        case jumpToPrompt(Int)
        case startSearch, findNext, findPrev, endSearch
        case reloadConfig
        case toggleSecureInput
    }

    public struct Trigger: Hashable, Sendable {
        public var keyCode: UInt16
        public var mods: UInt
    }

    public struct Table: Sendable, Equatable {
        public var map: [Trigger: Action] = [:]

        public init() {}

        public init(lines: [String]) {
            self = Table.parse(lines)
        }

        public static func parse(_ lines: [String]) -> Table {
            var table = Table()
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
                if line.isEmpty { continue }
                guard let parsed = parseLine(line) else { continue }
                for trigger in parsed.triggers {
                    table.map[trigger] = parsed.action
                }
            }
            return table
        }

        public func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Action? {
            let mods = flags.intersection(Self.hostMods).rawValue
            return map[Trigger(keyCode: keyCode, mods: mods)]
        }

        public func action(for event: NSEvent) -> Action? {
            action(keyCode: event.keyCode, flags: event.modifierFlags)
        }

        private static let hostMods: NSEvent.ModifierFlags = [
            .command, .shift, .control, .option,
        ]

        private static func parseLine(_ line: String) -> (triggers: [Trigger], action: Action)? {
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let trigger = line[..<eq].trimmingCharacters(in: .whitespaces)
            let actionRaw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if trigger.contains(":") { return nil }
            guard let action = parseAction(actionRaw) else { return nil }
            let parts = trigger.split(separator: "+").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let keyName = parts.last, !keyName.isEmpty else { return nil }
            var flags: NSEvent.ModifierFlags = []
            for mod in parts.dropLast() {
                switch mod {
                case "cmd", "command", "super": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl", "control": flags.insert(.control)
                case "opt", "option", "alt": flags.insert(.option)
                default: return nil
                }
            }
            guard let codes = keyCodes(keyName) else { return nil }
            let mods = flags.intersection(hostMods).rawValue
            return (codes.map { Trigger(keyCode: $0, mods: mods) }, action)
        }

        public static func parseAction(_ raw: String) -> Action? {
            if raw.hasPrefix("jump_to_prompt:") {
                let n = raw.dropFirst("jump_to_prompt:".count)
                guard let dir = Int(n) else { return nil }
                return .jumpToPrompt(dir)
            }
            switch raw {
            case "copy": return .copy
            case "paste": return .paste
            case "select_all": return .selectAll
            case "new_window": return .newWindow
            case "close_window": return .closeWindow
            case "increase_font_size": return .increaseFontSize
            case "decrease_font_size": return .decreaseFontSize
            case "reset_font_size": return .resetFontSize
            case "scroll_to_top": return .scrollToTop
            case "scroll_to_bottom": return .scrollToBottom
            case "scroll_page_up": return .scrollPageUp
            case "scroll_page_down": return .scrollPageDown
            case "start_search": return .startSearch
            case "find_next": return .findNext
            case "find_prev": return .findPrev
            case "end_search": return .endSearch
            case "reload_config": return .reloadConfig
            case "toggle_secure_input": return .toggleSecureInput
            default: return nil
            }
        }

        private static func keyCodes(_ name: String) -> [UInt16]? {
            switch name {
            case "up": return [UInt16(kVK_UpArrow)]
            case "down": return [UInt16(kVK_DownArrow)]
            case "left": return [UInt16(kVK_LeftArrow)]
            case "right": return [UInt16(kVK_RightArrow)]
            case "page_up": return [UInt16(kVK_PageUp)]
            case "page_down": return [UInt16(kVK_PageDown)]
            case "home": return [UInt16(kVK_Home)]
            case "end": return [UInt16(kVK_End)]
            case "enter", "return":
                return [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
            case "tab": return [UInt16(kVK_Tab)]
            case "space": return [UInt16(kVK_Space)]
            case "comma": return [UInt16(kVK_ANSI_Comma)]
            case "period": return [UInt16(kVK_ANSI_Period)]
            case "minus": return [UInt16(kVK_ANSI_Minus)]
            case "equal": return [UInt16(kVK_ANSI_Equal)]
            case "slash": return [UInt16(kVK_ANSI_Slash)]
            case "a": return [UInt16(kVK_ANSI_A)]
            case "b": return [UInt16(kVK_ANSI_B)]
            case "c": return [UInt16(kVK_ANSI_C)]
            case "d": return [UInt16(kVK_ANSI_D)]
            case "e": return [UInt16(kVK_ANSI_E)]
            case "f": return [UInt16(kVK_ANSI_F)]
            case "g": return [UInt16(kVK_ANSI_G)]
            case "h": return [UInt16(kVK_ANSI_H)]
            case "i": return [UInt16(kVK_ANSI_I)]
            case "j": return [UInt16(kVK_ANSI_J)]
            case "k": return [UInt16(kVK_ANSI_K)]
            case "l": return [UInt16(kVK_ANSI_L)]
            case "m": return [UInt16(kVK_ANSI_M)]
            case "n": return [UInt16(kVK_ANSI_N)]
            case "o": return [UInt16(kVK_ANSI_O)]
            case "p": return [UInt16(kVK_ANSI_P)]
            case "q": return [UInt16(kVK_ANSI_Q)]
            case "r": return [UInt16(kVK_ANSI_R)]
            case "s": return [UInt16(kVK_ANSI_S)]
            case "t": return [UInt16(kVK_ANSI_T)]
            case "u": return [UInt16(kVK_ANSI_U)]
            case "v": return [UInt16(kVK_ANSI_V)]
            case "w": return [UInt16(kVK_ANSI_W)]
            case "x": return [UInt16(kVK_ANSI_X)]
            case "y": return [UInt16(kVK_ANSI_Y)]
            case "z": return [UInt16(kVK_ANSI_Z)]
            case "0": return [UInt16(kVK_ANSI_0), UInt16(kVK_ANSI_Keypad0)]
            case "1": return [UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_Keypad1)]
            case "2": return [UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_Keypad2)]
            case "3": return [UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_Keypad3)]
            case "4": return [UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_Keypad4)]
            case "5": return [UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_Keypad5)]
            case "6": return [UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_Keypad6)]
            case "7": return [UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_Keypad7)]
            case "8": return [UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_Keypad8)]
            case "9": return [UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_Keypad9)]
            default: return nil
            }
        }
    }
}
