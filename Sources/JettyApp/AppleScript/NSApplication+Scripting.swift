import AppKit
import Foundation
import Jetty

enum JettyScripting {
    nonisolated static var isEnabled: Bool {
        onMain { (NSApp.delegate as? AppDelegate)?.config?.macosAppleScript ?? true }
    }

    @discardableResult
    nonisolated static func validate(_ command: NSScriptCommand) -> Bool {
        guard isEnabled else {
            command.scriptErrorNumber = errAEEventNotPermitted
            command.scriptErrorString = "AppleScript is disabled by the macos-applescript configuration."
            return false
        }
        return true
    }

    nonisolated static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        MainActor.assumeIsolated(body)
    }

    nonisolated static func objectSpecifier(key: String, uniqueID: String) -> NSScriptObjectSpecifier? {
        nonisolated(unsafe) var spec: NSScriptObjectSpecifier?
        MainActor.assumeIsolated {
            guard let desc = NSApplication.shared.classDescription as? NSScriptClassDescription else {
                return
            }
            spec = NSUniqueIDSpecifier(
                containerClassDescription: desc,
                containerSpecifier: nil,
                key: key,
                uniqueID: uniqueID
            )
        }
        return spec
    }
}

extension NSApplication {

    @objc(scriptWindows)
    var scriptWindows: [ScriptWindow] {
        guard JettyScripting.isEnabled, let app = delegate as? AppDelegate else { return [] }
        return orderedWindows.compactMap { win in
            app.terms.first { $0.window === win }.map(ScriptWindow.init)
        }
    }

    @objc(frontWindow)
    var frontWindow: ScriptWindow? { scriptWindows.first }

    @objc(valueInScriptWindowsWithUniqueID:)
    func valueInScriptWindows(uniqueID: String) -> ScriptWindow? {
        scriptWindows.first { $0.stableID == uniqueID }
    }

    @objc(terminals)
    var terminals: [ScriptTerminal] {
        scriptWindows.flatMap(\.terminals)
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        terminals.first { $0.stableID == uniqueID }
    }

    @objc(version)
    var scriptVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    @objc(handlePerformActionScriptCommand:)
    func handlePerformActionScriptCommand(_ command: NSScriptCommand) -> NSNumber? {
        guard JettyScripting.validate(command) else { return nil }
        guard let action = command.directParameter as? String else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing action string."
            return nil
        }
        guard let terminal = command.evaluatedArguments?["on"] as? ScriptTerminal else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing terminal target."
            return nil
        }
        return NSNumber(value: terminal.perform(action: action))
    }

    @objc(handleNewSurfaceConfigurationScriptCommand:)
    func handleNewSurfaceConfigurationScriptCommand(_ command: NSScriptCommand) -> NSDictionary? {
        guard JettyScripting.validate(command) else { return nil }
        do {
            return try ScriptSurfaceConfiguration(
                scriptRecord: command.evaluatedArguments?["configuration"] as? NSDictionary
            ).dictionaryRepresentation
        } catch {
            command.scriptErrorNumber = errAECoercionFail
            command.scriptErrorString = error.localizedDescription
            return nil
        }
    }

    @objc(handleNewWindowScriptCommand:)
    func handleNewWindowScriptCommand(_ command: NSScriptCommand) -> ScriptWindow? {
        guard JettyScripting.validate(command) else { return nil }
        guard let app = delegate as? AppDelegate else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Jetty app delegate is unavailable."
            return nil
        }
        let cfg: ScriptSurfaceConfiguration
        if let record = command.evaluatedArguments?["configuration"] as? NSDictionary {
            do {
                cfg = try ScriptSurfaceConfiguration(scriptRecord: record)
            } catch {
                command.scriptErrorNumber = errAECoercionFail
                command.scriptErrorString = error.localizedDescription
                return nil
            }
        } else {
            cfg = ScriptSurfaceConfiguration()
        }
        var cwd = cfg.workingDirectory
        if !cwd.isEmpty {
            let path = (cwd as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString =
                    "Initial working directory does not exist or is not a directory: \(path)"
                return nil
            }
            cwd = path
        }
        guard let term = app.openWindow(
            workingDirectory: cwd,
            fontSize: cfg.fontSize,
            initialInput: cfg.initialInput
        ) else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Failed to create window."
            return nil
        }
        return ScriptWindow(term: term)
    }

    @objc(handleQuitScriptCommand:)
    func handleQuitScriptCommand(_ command: NSScriptCommand) {
        guard JettyScripting.validate(command) else { return }
        terminate(nil)
    }
}
