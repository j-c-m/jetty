import Carbon.HIToolbox
import CPty
import XCTest
@testable import Jetty

final class QuitConfirmTests: XCTestCase {
    func testBoxLinesAreFixedWidth() {
        for mode in [QuitConfirm.Mode.quit, .close] {
            let lines = QuitConfirm.lines(mode: mode)
            XCTAssertEqual(lines.count, QuitConfirm.rows)
            for line in lines {
                XCTAssertEqual(line.count, QuitConfirm.cols, line)
            }
        }
        XCTAssertTrue(QuitConfirm.lines(mode: .quit)[1].contains("Quit Jetty?"))
        XCTAssertTrue(QuitConfirm.lines(mode: .close)[1].contains("Close window?"))
        XCTAssertEqual(QuitConfirm.instanceCount, QuitConfirm.rows * QuitConfirm.cols)
    }

    func testReplyYesNoAndSwallow() {
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_ANSI_Y), characters: "y", command: false),
            .yes
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_ANSI_N), characters: "n", command: false),
            .no
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_Return), characters: "\r", command: false),
            .yes
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_ANSI_KeypadEnter), characters: "\u{3}", command: false),
            .yes
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_Escape), characters: "\u{1b}", command: false),
            .no
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_ANSI_Q), characters: "q", command: true),
            .yes
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_ANSI_Q), characters: "q", command: false),
            .swallow
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_Shift), characters: nil, command: false),
            .ignore
        )
        XCTAssertEqual(
            QuitConfirm.reply(keyCode: UInt16(kVK_ANSI_W), characters: "w", command: true),
            .swallow
        )
    }

    func testShellNameClassifier() {
        XCTAssertEqual(jt_pty_is_shell_name(nil), 0)
        XCTAssertEqual(jt_pty_is_shell_name(""), 0)
        XCTAssertEqual(jt_pty_is_shell_name("zsh"), 1)
        XCTAssertEqual(jt_pty_is_shell_name("bash"), 1)
        XCTAssertEqual(jt_pty_is_shell_name("login"), 1)
        XCTAssertEqual(jt_pty_is_shell_name("fish"), 1)
        XCTAssertEqual(jt_pty_is_shell_name("nu"), 1)
        XCTAssertEqual(jt_pty_is_shell_name("/bin/zsh"), 1)
        XCTAssertEqual(jt_pty_is_shell_name("vim"), 0)
        XCTAssertEqual(jt_pty_is_shell_name("sleep"), 0)
        XCTAssertEqual(jt_pty_is_shell_name("python3"), 0)
        XCTAssertEqual(jt_pty_is_shell_name("tmux"), 0)
        XCTAssertEqual(jt_pty_has_nonshell(-1, 0), 0)
        XCTAssertEqual(jt_pty_has_nonshell(-1, -1), 0)
    }

    func testSleepProcessIsNonShell() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["8"]
        try task.run()
        defer {
            task.terminate()
            task.waitUntilExit()
        }
        XCTAssertTrue(waitUntil(timeout: 1) {
            task.isRunning && jt_pty_has_nonshell(-1, task.processIdentifier) == 1
        })
    }

    func testIdleZshIsShellOnly() throws {
        let zsh = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zsh) else {
            throw XCTSkip("no /bin/zsh")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: zsh)
        task.arguments = ["-f", "-c", "kill -STOP $$"]
        try task.run()
        defer {
            task.terminate()
            task.waitUntilExit()
        }
        XCTAssertTrue(waitUntil(timeout: 1) { task.isRunning })
        XCTAssertEqual(jt_pty_has_nonshell(-1, task.processIdentifier), 0)
    }

    func testZshChildSleepIsNonShell() throws {
        let zsh = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zsh) else {
            throw XCTSkip("no /bin/zsh")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: zsh)
        // `& wait` keeps zsh alive so we must walk children; `sleep 8` may exec.
        task.arguments = ["-f", "-c", "sleep 8 & wait"]
        try task.run()
        defer {
            task.terminate()
            task.waitUntilExit()
        }
        XCTAssertTrue(waitUntil(timeout: 1) {
            task.isRunning && jt_pty_has_nonshell(-1, task.processIdentifier) == 1
        })
    }

    private func waitUntil(timeout: TimeInterval, _ pred: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pred() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pred()
    }
}
