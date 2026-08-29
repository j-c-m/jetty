import Darwin
import Foundation

/// Kitty `read_shell_environment`: `$SHELL -l -i -c env` on a PTY, then VISUAL/EDITOR.
@MainActor
public enum ShellEnv {
    private static var cached: [String: String]?

    nonisolated static func loginShell(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let s = env["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()) {
            let sh = String(cString: pw.pointee.pw_shell)
            if !sh.isEmpty { return sh }
        }
        return "/bin/zsh"
    }

    nonisolated static func parseEnv0(_ data: Data) -> [String: String] {
        var env: [String: String] = [:]
        for raw in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let s = String(data: Data(raw), encoding: .utf8),
                  let eq = s.firstIndex(of: "=")
            else { continue }
            let k = String(s[..<eq])
            if k.isEmpty { continue }
            env[k] = String(s[s.index(after: eq)...])
        }
        return env
    }

    nonisolated static func editor(from env: [String: String]) -> String? {
        for key in ["VISUAL", "EDITOR"] {
            if let s = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    public static func loginShellEditor() -> String? {
        editor(from: probe())
    }

    static func probe() -> [String: String] {
        if let cached { return cached }
        let env = runProbe() ?? [:]
        cached = env
        return env
    }

    private static func runProbe() -> [String: String]? {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
        defer { if master >= 0 { close(master) } }
        let shell = loginShell()
        let base = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        let inner = (base == "bash" || base == "zsh")
            ? "builtin command env -0"
            : "command env -0"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", inner]
        let sl = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardInput = sl
        p.standardOutput = sl
        p.standardError = sl
        do {
            try p.run()
        } catch {
            close(slave)
            return nil
        }
        close(slave)
        let fl = fcntl(master, F_GETFL)
        if fl >= 0 { _ = fcntl(master, F_SETFL, fl | O_NONBLOCK) }
        var data = Data()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            drain(master, into: &data)
            if !p.isRunning { break }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        drain(master, into: &data)
        return parseEnv0(data)
    }

    private static func drain(_ fd: Int32, into data: inout Data) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(contentsOf: buf.prefix(Int(n)))
                continue
            }
            break
        }
    }
}
