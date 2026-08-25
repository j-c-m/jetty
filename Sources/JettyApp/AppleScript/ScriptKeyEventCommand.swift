import AppKit

@objc(JettyScriptKeyEventCommand)
final class ScriptKeyEventCommand: NSScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        guard JettyScripting.validate(self) else { return nil }
        guard let keyName = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing key name."
            return nil
        }
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }
        if let actionCode = evaluatedArguments?["action"] as? UInt32,
           actionCode == "GIrl".fourCharCode {
            return nil
        }
        var shift = false
        var option = false
        var control = false
        if let modsString = evaluatedArguments?["modifiers"] as? String {
            for part in modsString.split(separator: ",") {
                switch part.trimmingCharacters(in: .whitespaces).lowercased() {
                case "shift": shift = true
                case "option", "alt": option = true
                case "control", "ctrl": control = true
                case "": break
                case "command", "cmd", "super":
                    scriptErrorNumber = errAEEventFailed
                    scriptErrorString = "Command modifier cannot be sent to the terminal."
                    return nil
                default:
                    scriptErrorNumber = errAECoercionFail
                    scriptErrorString = "Unknown modifier in: \(modsString)"
                    return nil
                }
            }
        }
        guard terminal.sendKey(name: keyName, shift: shift, option: option, control: control) else {
            scriptErrorNumber = errAECoercionFail
            scriptErrorString = "Unknown key name: \(keyName)"
            return nil
        }
        return nil
    }
}

extension String {
    var fourCharCode: UInt32 {
        var r: UInt32 = 0
        for b in utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }
}
