import AppKit
import Jetty

@objc(JettyScriptTerminal)
final class ScriptTerminal: NSObject, @unchecked Sendable {
    private weak var term: TermWindow?

    init(term: TermWindow) {
        self.term = term
    }

    var liveTerm: TermWindow? { JettyScripting.onMain { term } }

    @objc(id)
    var stableID: String {
        guard JettyScripting.isEnabled else { return "" }
        return JettyScripting.onMain { term?.id.uuidString ?? "" }
    }

    @objc(title)
    var title: String {
        guard JettyScripting.isEnabled else { return "" }
        return JettyScripting.onMain { term?.session.title ?? "" }
    }

    @objc(workingDirectory)
    var workingDirectory: String {
        guard JettyScripting.isEnabled else { return "" }
        return JettyScripting.onMain { term?.session.workingDirectory ?? "" }
    }

    @objc(pid)
    var pid: Int {
        guard JettyScripting.isEnabled else { return 0 }
        return JettyScripting.onMain { Int(term?.session.childPID ?? 0) }
    }

    @objc(tty)
    var tty: String {
        guard JettyScripting.isEnabled else { return "" }
        return JettyScripting.onMain { term?.session.ttyName ?? "" }
    }

    func perform(action: String) -> Bool {
        guard JettyScripting.isEnabled else { return false }
        return JettyScripting.onMain {
            term?.view.performHostAction(action) ?? false
        }
    }

    func inputText(_ text: String) {
        JettyScripting.onMain {
            guard let term else { return }
            term.session.lock.lock()
            let bracketed = term.session.screen.bracketedPaste
            term.session.lock.unlock()
            term.session.writeToPty(Clipboard.pasteBytes(Array(text.utf8), bracketed: bracketed))
        }
    }

    func sendKey(name: String, shift: Bool, option: Bool, control: Bool) -> Bool {
        JettyScripting.onMain {
            guard let term else { return false }
            term.session.lock.lock()
            let appCursor = term.session.screen.decckm
            term.session.lock.unlock()
            guard let bytes = XtermKeyEncoder.bytes(
                named: name,
                shift: shift,
                option: option,
                control: control,
                applicationCursor: appCursor
            ) else { return false }
            term.session.writeToPty(bytes)
            return true
        }
    }

    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard JettyScripting.validate(command) else { return nil }
        let ok = JettyScripting.onMain { () -> Bool in
            guard let window = term?.window, let view = term?.view else { return false }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate()
            return true
        }
        if !ok {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is no longer available."
        }
        return nil
    }

    @objc(handleCloseCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        guard JettyScripting.validate(command) else { return nil }
        let ok = JettyScripting.onMain { () -> Bool in
            guard let window = term?.window else { return false }
            window.close()
            return true
        }
        if !ok {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Terminal is no longer available."
        }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard JettyScripting.isEnabled else { return nil }
        return JettyScripting.objectSpecifier(key: "terminals", uniqueID: stableID)
    }
}
