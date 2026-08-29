import Foundation
import XCTest
@testable import Jetty

final class CommandOutputTests: XCTestCase {
    private let C = UInt8(ascii: "C")
    private let D = UInt8(ascii: "D")
    private let A = UInt8(ascii: "A")

    func testSpanInsideCommand() {
        let marks: [(UInt64, UInt8)] = [(10, A), (11, C), (21, D), (21, A)]
        let s = CommandOutput.span(marks: marks, at: 15, liveEnd: 40)
        XCTAssertEqual(s?.start, 11)
        XCTAssertEqual(s?.end, 21)
    }

    func testSpanOnPromptIsNil() {
        let marks: [(UInt64, UInt8)] = [(11, C), (21, D), (21, A)]
        XCTAssertNil(CommandOutput.span(marks: marks, at: 21, liveEnd: 40))
        XCTAssertNil(CommandOutput.span(marks: marks, at: 10, liveEnd: 40))
    }

    func testUnclosedCUsesLiveEnd() {
        let marks: [(UInt64, UInt8)] = [(5, C)]
        let s = CommandOutput.span(marks: marks, at: 8, liveEnd: 12)
        XCTAssertEqual(s?.start, 5)
        XCTAssertEqual(s?.end, 12)
    }

    func testLastCWins() {
        let marks: [(UInt64, UInt8)] = [(1, C), (4, D), (5, C), (9, D)]
        let s = CommandOutput.span(marks: marks, at: 7, liveEnd: 20)
        XCTAssertEqual(s?.start, 5)
        XCTAssertEqual(s?.end, 9)
    }

    func testDocLineRoundTrip() {
        XCTAssertEqual(CommandOutput.docLine(liveY: 0, linesScrolled: 15), 15)
        XCTAssertEqual(CommandOutput.docLine(liveY: 2, linesScrolled: 15), 17)
        XCTAssertEqual(CommandOutput.docLine(liveY: -1, linesScrolled: 15), 14)
        XCTAssertEqual(CommandOutput.liveY(doc: 14, linesScrolled: 15), -1)
        XCTAssertEqual(CommandOutput.liveY(doc: 17, linesScrolled: 15), 2)
    }

    func testExitCodeFromOpts() {
        XCTAssertEqual(CommandOutput.exitCode(opts: Array("D;0".utf8)), 0)
        XCTAssertEqual(CommandOutput.exitCode(opts: Array("D;127;aid=1".utf8)), 127)
        XCTAssertNil(CommandOutput.exitCode(opts: Array("D".utf8)))
        XCTAssertNil(CommandOutput.exitCode(opts: Array("C;".utf8)))
    }
}

final class ShellInjectTests: XCTestCase {
    func testDetectsBasename() {
        XCTAssertEqual(ShellInject.kind(config: .detect, shell: "/opt/homebrew/bin/zsh"), .zsh)
        XCTAssertEqual(ShellInject.kind(config: .detect, shell: "/usr/local/bin/fish"), .fish)
        XCTAssertEqual(ShellInject.kind(config: .detect, shell: "/opt/homebrew/bin/bash"), .bash)
        XCTAssertEqual(ShellInject.kind(config: .none, shell: "/bin/zsh"), .none)
        XCTAssertEqual(ShellInject.kind(config: .fish, shell: "/bin/zsh"), .fish)
    }

    func testSkipsAppleBash() {
        XCTAssertTrue(ShellInject.skipAppleBash("/bin/bash"))
        XCTAssertEqual(ShellInject.kind(config: .detect, shell: "/bin/bash"), .none)
        XCTAssertEqual(ShellInject.kind(config: .bash, shell: "/bin/bash"), .none)
        XCTAssertFalse(ShellInject.skipAppleBash("/opt/homebrew/bin/bash"))
    }

    func testZshEnvSetsZdotdir() {
        let kind = ShellInject.kind(config: .zsh, shell: "/bin/zsh")
        let env = ShellInject.extraEnv(kind: kind)
        if ShellInject.resourceRoot() == nil {
            XCTAssertTrue(env.isEmpty)
            return
        }
        XCTAssertTrue(env.contains { $0.hasPrefix("ZDOTDIR=") })
    }

    func testKittyOsc7Path() {
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("file:///Users/me/src"),
            "/Users/me/src"
        )
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("file://localhost/tmp"),
            "/tmp"
        )
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("file://host/tmp/foo?bar"),
            "/tmp/foo?bar"
        )
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("file://host/tmp/foo#frag"),
            "/tmp/foo#frag"
        )
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("file://host/tmp/foo%3Fbar"),
            "/tmp/foo?bar"
        )
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("kitty-shell-cwd://host/Users/me/src"),
            "/Users/me/src"
        )
        XCTAssertEqual(
            TerminalSession.pathFromOSC7("kitty-shell-cwd://host/tmp/foo?bar"),
            "/tmp/foo?bar"
        )
        XCTAssertEqual(TerminalSession.pathFromOSC7("http://example.com"), "")
    }

    func testZshReturnStillInjects() throws {
        let zdot = try shellFile("zsh")
        let jetty = zdot.appendingPathComponent("jetty.zsh")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: jetty.path))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetty-zsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "return 0\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let r = try run(
            "/bin/zsh",
            ["-i", "-c", "typeset -f _jetty_precmd >/dev/null && print HAS_HOOK"],
            env: [
                "HOME": home.path,
                "ZDOTDIR": zdot.path,
                "TERM": "dumb",
            ]
        )
        XCTAssertTrue(r.out.contains("HAS_HOOK"), "stdout=\(r.out) stderr=\(r.err) status=\(r.status)")
    }

    func testZshDefersFirstAAndReappendsPrecmd() throws {
        let jetty = try shellFile("zsh/jetty.zsh")
        let r = try run(
            "/bin/zsh",
            ["-f", "-i", "-c", """
            source \(shellQuote(jetty.path))
            print -- MARK_LOAD
            print -- $precmd_functions
            _jetty_deferred_init
            precmd_functions=(_jetty_precmd other)
            _jetty_precmd
            print -- MARK_LAST
            print -- ${precmd_functions[-1]}
            """],
            env: ["TERM": "dumb", "HOME": FileManager.default.temporaryDirectory.path]
        )
        let beforeLoad = r.out.components(separatedBy: "MARK_LOAD").first ?? r.out
        XCTAssertFalse(beforeLoad.contains("]133;A"), "first A must wait for precmd: \(r.out)")
        XCTAssertTrue(r.out.contains("_jetty_deferred_init"), r.out)
        let last = r.out.components(separatedBy: "MARK_LAST").last ?? ""
        XCTAssertTrue(last.contains("_jetty_precmd"), "stdout=\(r.out) stderr=\(r.err)")
    }

    func testBashPromptCommandPreservesArray() throws {
        let bash = try bash44()
        let script = try shellFile("bash/jetty.bash")
        let r = try run(
            bash,
            ["--noprofile", "--norc", "-ic", """
            PROMPT_COMMAND=("starship_precmd")
            source \(shellQuote(script.path))
            declare -p PROMPT_COMMAND
            """],
            env: ["TERM": "dumb"]
        )
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("declare -a"), "expected array, got \(r.out)")
        XCTAssertTrue(r.out.contains("starship_precmd"), r.out)
        XCTAssertTrue(r.out.contains("_jetty_hook"), r.out)
    }

    func testBashPromptCommandEmptyIsArrayOn51() throws {
        let bash = try bash44()
        guard try bashVersion(bash) >= (5, 1) else {
            throw XCTSkip("bash 5.1+ required for PROMPT_COMMAND array default")
        }
        let script = try shellFile("bash/jetty.bash")
        let r = try run(
            bash,
            ["--noprofile", "--norc", "-ic", """
            unset PROMPT_COMMAND
            source \(shellQuote(script.path))
            declare -p PROMPT_COMMAND
            """],
            env: ["TERM": "dumb"]
        )
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.out.contains("declare -a"), "empty 5.1+ must be an array: \(r.out)")
        XCTAssertTrue(r.out.contains("_jetty_hook"), r.out)
    }

    func testOsc7SnippetsUseKittyScheme() throws {
        for sub in ["bash/jetty.bash", "zsh/jetty.zsh", "nushell/vendor/autoload/jetty.nu"] {
            let text = try String(contentsOf: try shellFile(sub), encoding: .utf8)
            XCTAssertTrue(text.contains("kitty-shell-cwd://"), sub)
            XCTAssertFalse(text.contains("file://"), sub)
        }
        let fish = try String(contentsOf: try shellFile("fish/vendor_conf.d/jetty.fish"), encoding: .utf8)
        XCTAssertTrue(fish.contains("file://"), fish)
        XCTAssertTrue(fish.contains("string escape --style=url"), fish)
    }

    func testFishDefersPromptSetup() throws {
        let text = try String(contentsOf: try shellFile("fish/vendor_conf.d/jetty.fish"), encoding: .utf8)
        XCTAssertTrue(text.contains("function __jetty_setup --on-event fish_prompt"), text)
        XCTAssertTrue(text.contains("functions -e __jetty_setup"), text)
        XCTAssertFalse(text.contains("\n__jetty_prompt\n__jetty_cwd\n"), text)
    }

    func testNushellSnippetKeepsHooksRecord() throws {
        let text = try String(contentsOf: try shellFile("nushell/vendor/autoload/jetty.nu"), encoding: .utf8)
        XCTAssertTrue(text.contains("| upsert hooks ("), text)
        XCTAssertFalse(text.contains("upsert hooks {"), text)
    }

    func testNushellMergesHooks() throws {
        let nu = try nuBin()
        let script = try shellFile("nushell/vendor/autoload/jetty.nu")
        let r = try run(
            nu,
            ["--no-config-file", "-c", """
            $env.config = ($env.config | default {} | upsert hooks { display_output: {|| "kept"} })
            source \(shellQuote(script.path))
            print ($env.config.hooks.display_output | describe)
            print ($env.config.hooks.pre_prompt | describe)
            print ($env.config.hooks.pre_execution | describe)
            """],
            env: ["TERM": "dumb"]
        )
        XCTAssertEqual(r.status, 0, "stderr=\(r.err) stdout=\(r.out)")
        XCTAssertTrue(r.out.contains("closure") || r.out.contains("block"), "display_output dropped: \(r.out)")
        XCTAssertTrue(r.out.contains("list"), "expected appended hook lists: \(r.out)")
    }

    private func shellFile(_ sub: String) throws -> URL {
        if let root = ShellInject.resourceRoot() {
            let u = root.appendingPathComponent(sub)
            if FileManager.default.isReadableFile(atPath: u.path) || FileManager.default.fileExists(atPath: u.path) {
                return u
            }
        }
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Jetty/Resources/Shell")
            .appendingPathComponent(sub)
        if FileManager.default.fileExists(atPath: src.path) { return src }
        throw XCTSkip("shell snippet missing: \(sub)")
    }

    private func bash44() throws -> String {
        let candidates = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            if try bashVersion(p) >= (4, 4) { return p }
        }
        throw XCTSkip("bash 4.4+ not installed")
    }

    private func bashVersion(_ exe: String) throws -> (Int, Int) {
        let r = try run(exe, ["-c", #"printf '%s %s' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}""#])
        let parts = r.out.split(separator: " ").compactMap { Int($0) }
        guard parts.count >= 2 else { throw XCTSkip("could not read bash version: \(r.out)") }
        return (parts[0], parts[1])
    }

    private func nuBin() throws -> String {
        for p in ["/opt/homebrew/bin/nu", "/usr/local/bin/nu"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        throw XCTSkip("nu not installed")
    }



    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func run(_ exe: String, _ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let er = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (o, er, p.terminationStatus)
    }
}
