import CPty
import XCTest
@testable import Jetty

final class SecureInputTests: XCTestCase {
    func testMasterReflectsSlaveEcho() throws {
        let r = jt_pty_probe_master_echo()
        if r < 0 {
            throw XCTSkip("openpty failed")
        }
        XCTAssertEqual(r, 1, "Darwin PTY master should see slave ICANON && !ECHO")
    }

    func testPasswordPromptRejectsBadFd() {
        XCTAssertEqual(jt_pty_password_prompt(-1), -1)
        XCTAssertFalse(SecureInput.passwordPrompt(fd: -1))
    }
}
