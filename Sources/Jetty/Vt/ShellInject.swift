import Foundation

/// OSC 7 + OSC 133 inject. No sudo wrap, no terminfo, no `TERM` change.
public enum ShellInject: Sendable {
    public enum Kind: Sendable, Equatable {
        case none, bash, zsh, fish, nu
    }

    public static func kind(
        config: AppConfig.ShellIntegration,
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? ""
    ) -> Kind {
        switch config {
        case .none: return Kind.none
        case .bash: return skipAppleBash(shell) ? Kind.none : .bash
        case .zsh: return .zsh
        case .fish: return .fish
        case .nu: return .nu
        case .detect:
            let base = (shell as NSString).lastPathComponent
            switch base {
            case "zsh": return .zsh
            case "fish": return .fish
            case "nu", "nushell": return .nu
            case "bash": return skipAppleBash(shell) ? Kind.none : .bash
            default: return Kind.none
            }
        }
    }

    /// Darwin `/bin/bash` is 3.2 and ignores `ENV`.
    public static func skipAppleBash(_ shell: String) -> Bool {
        #if os(macOS)
        (shell as NSString).standardizingPath == "/bin/bash"
        #else
        false
        #endif
    }

    public static func extraEnv(kind: Kind) -> [String] {
        guard kind != .none, let root = resourceRoot() else { return [] }
        let env = ProcessInfo.processInfo.environment
        switch kind {
        case .none:
            return []
        case .bash:
            let script = root.appendingPathComponent("bash/jetty.bash").path
            var out = ["ENV=\(script)", "JETTY_BASH_INJECT=1"]
            if let old = env["ENV"], !old.isEmpty {
                out.append("JETTY_BASH_ENV=\(old)")
            }
            return out
        case .zsh:
            let zdot = root.appendingPathComponent("zsh").path
            var out = ["ZDOTDIR=\(zdot)"]
            if let old = env["ZDOTDIR"], !old.isEmpty {
                out.append("JETTY_ZSH_ZDOTDIR=\(old)")
            }
            return out
        case .fish, .nu:
            let def = env["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "/usr/local/share:/usr/share"
            return [
                "XDG_DATA_DIRS=\(root.path):\(def)",
                "JETTY_SHELL_XDG_DIR=\(root.path)",
            ]
        }
    }

    public static func resourceRoot() -> URL? {
        Bundle.module.url(forResource: "Shell", withExtension: nil, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "Shell", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("Resources/Shell")
    }
}
