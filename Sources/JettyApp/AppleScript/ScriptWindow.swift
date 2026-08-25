import AppKit

@objc(JettyScriptWindow)
final class ScriptWindow: NSObject, @unchecked Sendable {
    let stableID: String
    private weak var term: TermWindow?

    init(term: TermWindow) {
        self.stableID = term.id.uuidString
        self.term = term
    }

    @objc(id)
    var idValue: String {
        guard JettyScripting.isEnabled else { return "" }
        return stableID
    }

    @objc(title)
    var title: String {
        guard JettyScripting.isEnabled else { return "" }
        return JettyScripting.onMain { term?.window.title ?? "" }
    }

    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard JettyScripting.isEnabled else { return [] }
        return JettyScripting.onMain {
            guard let term else { return [] }
            return [ScriptTerminal(term: term)]
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        terminals.first { $0.stableID == uniqueID }
    }

    @objc(handleActivateWindowCommand:)
    func handleActivateWindow(_ command: NSScriptCommand) -> Any? {
        guard JettyScripting.validate(command) else { return nil }
        let ok = JettyScripting.onMain { () -> Bool in
            guard let window = term?.window else { return false }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return true
        }
        if !ok {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
        }
        return nil
    }

    @objc(handleCloseWindowCommand:)
    func handleCloseWindow(_ command: NSScriptCommand) -> Any? {
        guard JettyScripting.validate(command) else { return nil }
        let ok = JettyScripting.onMain { () -> Bool in
            guard let window = term?.window else { return false }
            window.close()
            return true
        }
        if !ok {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Window is no longer available."
        }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard JettyScripting.isEnabled else { return nil }
        return JettyScripting.objectSpecifier(key: "scriptWindows", uniqueID: stableID)
    }
}
