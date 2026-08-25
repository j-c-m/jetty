import AppKit

@objc(JettyScriptInputTextCommand)
final class ScriptInputTextCommand: NSScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        guard JettyScripting.validate(self) else { return nil }
        guard let text = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing text to input."
            return nil
        }
        guard let terminal = evaluatedArguments?["terminal"] as? ScriptTerminal else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Missing terminal target."
            return nil
        }
        guard terminal.liveTerm != nil else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Terminal is no longer available."
            return nil
        }
        terminal.inputText(text)
        return nil
    }
}
