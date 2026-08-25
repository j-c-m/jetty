import Foundation

struct ScriptSurfaceConfiguration {
    var fontSize: Double = 0
    var workingDirectory: String = ""
    var command: String = ""
    var initialInput: String = ""
    var waitAfterCommand = false
    var environmentVariables: [String] = []

    enum ParseError: Error, LocalizedError {
        case invalidType(String, String)
        case invalidValue(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidType(let parameter, let expected):
                return "\(parameter) must be \(expected)."
            case .invalidValue(let parameter, let message):
                return "\(parameter) \(message)."
            }
        }
    }

    init() {}

    init(scriptRecord source: NSDictionary?) throws {
        self.init()
        guard let source else { return }
        guard let raw = source as? [String: Any] else {
            throw ParseError.invalidType("configuration", "a surface configuration record")
        }
        if let rawFontSize = raw["fontSize"] {
            guard let number = rawFontSize as? NSNumber else {
                throw ParseError.invalidType("font size", "a number")
            }
            let value = number.doubleValue
            guard value.isFinite else {
                throw ParseError.invalidValue("font size", "must be a finite number")
            }
            if value < 0 {
                throw ParseError.invalidValue("font size", "must be a positive number")
            }
            if value > 0 { fontSize = value }
        }
        if let rawWorkingDirectory = raw["workingDirectory"] {
            guard let workingDirectory = rawWorkingDirectory as? String else {
                throw ParseError.invalidType("initial working directory", "text")
            }
            self.workingDirectory = workingDirectory
        }
        if let rawCommand = raw["command"] {
            guard let command = rawCommand as? String else {
                throw ParseError.invalidType("command", "text")
            }
            self.command = command
        }
        if let rawInitialInput = raw["initialInput"] {
            guard let initialInput = rawInitialInput as? String else {
                throw ParseError.invalidType("initial input", "text")
            }
            self.initialInput = initialInput
        }
        if let rawWait = raw["waitAfterCommand"] {
            if let boolValue = rawWait as? Bool {
                waitAfterCommand = boolValue
            } else if let numericValue = rawWait as? NSNumber {
                waitAfterCommand = numericValue.boolValue
            } else {
                throw ParseError.invalidType("wait after command", "boolean")
            }
        }
        if let assignments = raw["environmentVariables"] as? [String] {
            environmentVariables = assignments
        }
    }

    var dictionaryRepresentation: NSDictionary {
        [
            "fontSize": fontSize,
            "workingDirectory": workingDirectory,
            "command": command,
            "initialInput": initialInput,
            "waitAfterCommand": waitAfterCommand,
            "environmentVariables": environmentVariables,
        ] as NSDictionary
    }
}
