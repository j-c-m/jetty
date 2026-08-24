import CVt
import XCTest
@testable import Jetty

final class ParserTests: XCTestCase {
    func testASCIIRun() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("hello")
        XCTAssertEqual(s.plainString(), "hello")
        XCTAssertEqual(s.cursorX, 5)
    }

    func testWrap() {
        let s = Screen(cols: 4, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("abcde")
        XCTAssertEqual(s.plainString(), "abcd\ne")
        XCTAssertTrue(s.isWrapped(0))
    }

    func testRISClears() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("hello")
        p.feed("\u{1B}c")
        XCTAssertEqual(s.plainString(), "")
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 0)
    }

    func testRISClearsScrollback() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 8)
        let p = Parser()
        p.screen = s
        p.feed("AAAABBBBCCCC")
        XCTAssertGreaterThan(s.scrollbackCount, 0)
        p.feed("\u{1B}c")
        XCTAssertEqual(s.scrollbackCount, 0)
        XCTAssertEqual(s.plainString(), "")
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 0)
    }

    func testLinuxFnDoesNotSwallow() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[[A")
        XCTAssertEqual(s.plainString(), "A")
    }

    func testIncompleteOSCDoesNotLeak() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]0;title")
        p.feed("X")
        XCTAssertEqual(s.plainString(), "")
        p.feed("\u{07}")
        p.feed("Y")
        XCTAssertEqual(s.plainString(), "Y")
    }

    func testDA1() {
        let p = Parser()
        p.feed("\u{1B}[c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1;2c")
    }

    func testDA2() {
        let p = Parser()
        p.feed("\u{1B}[>c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[>0;0;0c")
        p.writes.removeAll()
        p.feed("\u{1B}[>0c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[>0;0;0c")
        p.writes.removeAll()
        p.feed("\u{1B}[c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1;2c")
    }

    func testXTVERSION() {
        let p = Parser()
        p.feed("\u{1B}[>0q")
        let ver = "\u{1B}P>|jetty \(JT_VERSION)\u{1B}\\"
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), ver)
        p.writes.removeAll()
        p.feed("\u{1B}[>q")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), ver)
        p.writes.removeAll()
        p.feed("\u{1B}[ q")
        XCTAssertEqual(p.writes, [])
    }

    func testDECRQM2026() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2026$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2026;2$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?2026h")
        p.feed("\u{1B}[?2026$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2026;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?2026l")
        p.feed("\u{1B}[?2026$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2026;2$y")
        XCTAssertFalse(s.syncOutput)
        p.feed("\u{1B}[?2026h")
        XCTAssertTrue(s.syncOutput)
    }

    func testDec2026HoldTimeout() {
        XCTAssertTrue(Dec2026.skipPresent(sync: true, flush: false, holdStart: 0, now: 1))
        XCTAssertTrue(Dec2026.skipPresent(sync: true, flush: false, holdStart: 10, now: 10))
        XCTAssertTrue(Dec2026.skipPresent(
            sync: true, flush: false, holdStart: 10, now: 10 + Dec2026.timeoutNs - 1))
        XCTAssertFalse(Dec2026.skipPresent(
            sync: true, flush: false, holdStart: 10, now: 10 + Dec2026.timeoutNs))
        XCTAssertFalse(Dec2026.skipPresent(sync: false, flush: false, holdStart: 10, now: 10))
        XCTAssertFalse(Dec2026.skipPresent(sync: true, flush: true, holdStart: 0, now: 1))
    }

    func testDec2026LThenHStillFlushes() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?2026h")
        XCTAssertTrue(s.syncOutput)
        XCTAssertFalse(s.syncFlush)
        p.feed("\u{1B}[?2026l\u{1B}[?2026h")
        XCTAssertTrue(s.syncOutput)
        XCTAssertTrue(s.syncFlush)
        XCTAssertFalse(Dec2026.skipPresent(
            sync: s.syncOutput, flush: s.syncFlush, holdStart: 0, now: 1))
        XCTAssertFalse(Dec2026.peekSkip(s.implPtr, holdStart: 0, now: 1))
    }

    func testSyncPeekDoesNotBlockOnHeldLock() {
        let session = TerminalSession(cols: 8, rows: 2, scrollbackCapRows: 0)
        session.parser.feed("\u{1B}[?2026h")
        XCTAssertTrue(session.screen.syncOutput)
        session.lock.lock()
        let exp = expectation(description: "peekSkip")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertTrue(Dec2026.peekSkip(session.screen.implPtr, holdStart: 0, now: 1))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.25)
        session.lock.unlock()
    }

    func testDECRQMDefaultsAndPermanent() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?1007$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1007;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?25$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?25;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?3$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?3;4$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1005$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1005;4$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?9999$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?9999;0$y")
        p.writes.removeAll()
        p.feed("\u{1B}[4$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[4;2$y")
        p.writes.removeAll()
        p.feed("\u{1B}[4h")
        p.feed("\u{1B}[4$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[4;1$y")
    }

    func testDECRQMMouseAndAlt() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?1000;1006h")
        p.feed("\u{1B}[?1000$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1000;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1006$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1006;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1049h")
        p.feed("\u{1B}[?1049$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1049;1$y")
    }

    func testBracketedPasteAndFocusModes() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertFalse(s.focusEvent)
        p.feed("\u{1B}[?2004;1004h")
        XCTAssertTrue(s.bracketedPaste)
        XCTAssertTrue(s.focusEvent)
        p.feed("\u{1B}[?2004$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?2004;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?1004$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1004;1$y")
        p.writes.removeAll()
        p.feed("\u{1B}[?2004l")
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertTrue(s.focusEvent)
        p.feed("\u{1B}c")
        XCTAssertFalse(s.bracketedPaste)
        XCTAssertFalse(s.focusEvent)
    }

    func testOSCTitleAndST() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]0;hello\u{07}")
        XCTAssertEqual(p.titles, ["hello"])
        p.feed("\u{1B}]2;world\u{1B}\\")
        XCTAssertEqual(p.titles.last, "world")
        p.feed("\u{1B}]0;\u{202A}bad\u{07}")
        XCTAssertEqual(p.titles.last, "bad")
    }

    func testOSC4AndDefaults() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]4;1;#FF0000\u{07}")
        XCTAssertEqual(s.paletteColor(1), RGB(r: 255, g: 0, b: 0))
        p.writes.removeAll()
        p.feed("\u{1B}]4;1;?\u{07}")
        let q = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(q.contains("]4;1;rgb:FFFF/0000/0000"), q)
        p.feed("\u{1B}]10;#010203\u{07}")
        XCTAssertEqual(s.defaultFgRGB, RGB(r: 1, g: 2, b: 3))
        p.feed("\u{1B}]11;rgb:00/FF/00\u{07}")
        XCTAssertEqual(s.defaultBgRGB, RGB(r: 0, g: 255, b: 0))
        p.feed("\u{1B}]112\u{07}")
        p.feed("\u{1B}]10;?\u{07}")
        XCTAssertTrue((String(bytes: p.writes, encoding: .utf8) ?? "").contains("]10;"))
        p.feed("\u{1B}]4;1;#FF0000\u{07}")
        p.feed("\u{1B}]104;1\u{07}")
        XCTAssertNotEqual(s.paletteColor(1), RGB(r: 255, g: 0, b: 0))
        let n = p.notifies.count
        p.feed("\u{1B}]21;foo\u{07}")
        p.feed("\u{1B}]66;bar\u{07}")
        p.feed("\u{1B}]9;3;tab\u{07}")
        XCTAssertEqual(p.notifies.count, n)
    }

    func testOSC52() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(p.osc52Writes.count, 1)
        XCTAssertEqual(p.osc52Writes[0].kind, UInt8(ascii: "c"))
        XCTAssertEqual(String(bytes: p.osc52Writes[0].b64, encoding: .ascii), "aGVsbG8=")
        p.feed("\u{1B}]52;c;?\u{07}")
        XCTAssertEqual(p.osc52Reads, [UInt8(ascii: "c")])
        p.feed("\u{1B}]52;x;?\u{07}")
        XCTAssertEqual(p.osc52Reads.last, UInt8(ascii: "c"))
    }

    func testOSC8And7And133() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}]8;id=foo;https://example.com\u{07}A")
        XCTAssertNotEqual(s.row(0)[0].extra, 0)
        XCTAssertEqual(s.uri(at: 0, y: 0), "https://example.com")
        p.feed("\u{1B}]8;;\u{07}B")
        XCTAssertEqual(s.row(0)[1].extra, 0)
        p.feed("\u{1B}]7;file://host/tmp\u{07}")
        XCTAssertEqual(p.osc7.last, "file://host/tmp")
        p.feed("\u{1B}]133;A\u{07}")
        XCTAssertEqual(p.osc133.last?.0, UInt8(ascii: "A"))
    }

    func testOSC9NotifyAndProgress() {
        let p = Parser()
        p.feed("\u{1B}]9;hello from jetty\u{07}")
        XCTAssertEqual(p.notifies.last?.0, "jetty")
        XCTAssertEqual(p.notifies.last?.1, "hello from jetty")
        let n0 = p.notifies.count
        p.feed("\u{1B}]9;4;1;40\u{07}")
        XCTAssertEqual(p.progress.last?.0, 1)
        XCTAssertEqual(p.progress.last?.1, 40)
        p.feed("\u{1B}]9;4;2;80\u{07}")
        XCTAssertEqual(p.progress.last?.0, 2)
        XCTAssertEqual(p.progress.last?.1, 80)
        p.feed("\u{1B}]9;4;3\u{07}")
        XCTAssertEqual(p.progress.last?.0, 3)
        p.feed("\u{1B}]9;4;4;50\u{07}")
        XCTAssertEqual(p.progress.last?.0, 4)
        XCTAssertEqual(p.progress.last?.1, 50)
        p.feed("\u{1B}]9;4;1;150\u{07}")
        XCTAssertEqual(p.progress.last?.1, 100)
        p.feed("\u{1B}]9;4;1;-1\u{07}")
        XCTAssertEqual(p.progress.last?.0, 1)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;0\u{07}")
        XCTAssertEqual(p.progress.last?.0, 0)
        XCTAssertEqual(p.notifies.count, n0)
        p.feed("\u{1B}]9;4\u{07}")
        p.feed("\u{1B}]9;4;5\u{07}")
        XCTAssertEqual(p.notifies.count, n0)
        let n = p.notifies.count
        p.feed("\u{1B}]9;1;sleep\u{07}")
        p.feed("\u{1B}]9;2;box\u{07}")
        p.feed("\u{1B}]9;\u{07}")
        XCTAssertEqual(p.notifies.count, n)
        p.feed("\u{1B}]9;st body\u{1B}\\")
        XCTAssertEqual(p.notifies.last?.1, "st body")
    }

    func testOSC9OmittedPercentMatchesGhostty() {
        let p = Parser()
        p.feed("\u{1B}]9;4;1\u{07}")
        XCTAssertEqual(p.progress.last?.0, 1)
        XCTAssertEqual(p.progress.last?.1, 0)
        p.feed("\u{1B}]9;4;1;\u{07}")
        XCTAssertEqual(p.progress.last?.0, 1)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;1;-1\u{07}")
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;2\u{07}")
        XCTAssertEqual(p.progress.last?.0, 2)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;2;-1\u{07}")
        XCTAssertEqual(p.progress.last?.0, 2)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;4\u{07}")
        XCTAssertEqual(p.progress.last?.0, 4)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;4;-1\u{07}")
        XCTAssertEqual(p.progress.last?.0, 4)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;3\u{07}")
        XCTAssertEqual(p.progress.last?.0, 3)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;3;50\u{07}")
        XCTAssertEqual(p.progress.last?.0, 3)
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;1;40;\u{07}")
        XCTAssertEqual(p.progress.last?.1, 255)
        p.feed("\u{1B}]9;4;0;100\u{07}")
        XCTAssertEqual(p.progress.last?.0, 0)
        XCTAssertEqual(p.progress.last?.1, 255)
    }

    func testOSC777Notify() {
        let p = Parser()
        p.feed("\u{1B}]777;notify;Build;done\u{07}")
        XCTAssertEqual(p.notifies.last?.0, "Build")
        XCTAssertEqual(p.notifies.last?.1, "done")
        p.feed("\u{1B}]777;notify;;body only\u{07}")
        XCTAssertEqual(p.notifies.last?.0, "jetty")
        XCTAssertEqual(p.notifies.last?.1, "body only")
        let n = p.notifies.count
        p.feed("\u{1B}]777;other;x\u{07}")
        XCTAssertEqual(p.notifies.count, n)
    }

    func testOSC9StripsC0() {
        let p = Parser()
        p.feed("\u{1B}]9;a\u{01}b\u{07}")
        XCTAssertEqual(p.notifies.last?.1, "ab")
        p.feed("\u{1B}]9;a\u{202E}b\u{07}")
        XCTAssertEqual(p.notifies.last?.1, "ab")
        p.feed("\u{1B}]9;" + String(repeating: "x", count: 2000) + "\u{07}")
        XCTAssertEqual(p.notifies.last?.1.count, 1024)
    }

    func testCSI14And18t() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        var kinds: [Int32] = []
        p.onSizeReport = { kinds.append($0) }
        p.feed("\u{1B}[14t")
        p.feed("\u{1B}[18t")
        p.feed("\u{1B}[16t")
        p.feed("\u{1B}[21t")
        p.feed("\u{1B}[22t")
        p.feed("\u{1B}[22;1t")
        p.feed("\u{1B}[22;0t")
        p.feed("\u{1B}[23;2t")
        p.feed("\u{1B}[22;0;0t")
        p.feed("\u{1B}[14;1t")
        XCTAssertEqual(kinds, [14, 18, 16, 22, 23, 22])
    }

    func testXTGETTCAPAndDECRQSS() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}P+q636F6C6F7273\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1+r636F6C6F7273=323536\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}P+q636F6C6F7273;6B6273\u{1B}\\")
        XCTAssertEqual(
            String(bytes: p.writes, encoding: .utf8),
            "\u{1B}P1+r636F6C6F7273=323536\u{1B}\\\u{1B}P1+r6B6273=7F\u{1B}\\"
        )
        p.writes.removeAll()
        p.feed("\u{1B}P+q00;636F6C6F7273\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1+r636F6C6F7273=323536\u{1B}\\")
        p.writes.removeAll()
        let setulc = "536574756C63"
        p.feed("\u{1B}P+q" + Array(repeating: setulc, count: 40).joined(separator: ";") + "\u{1B}\\")
        let many = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertFalse(many.contains("P0+r"), many)
        XCTAssertEqual(many.components(separatedBy: "\u{1B}P1+r\(setulc)=").count - 1, 40)
        p.writes.removeAll()
        p.feed("\u{1B}P$qm\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1$r0m\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}P+q5463\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1+r5463\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}P+q524742\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1+r524742=38\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}P+q544E\u{1B}\\")
        XCTAssertEqual(
            String(bytes: p.writes, encoding: .utf8),
            "\u{1B}P1+r544E=787465726D2D323536636F6C6F72\u{1B}\\"
        )
        p.writes.removeAll()
        p.feed("\u{1B}[1;31m\u{1B}P$qm\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1$r0;1;31m\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}[0;4:3m\u{1B}P$qm\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1$r0;4:3m\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}[0;38:2::1:2:3m\u{1B}P$qm\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1$r0;38:2::1:2:3m\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}[0m\u{1B}P$qm\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P1$r0m\u{1B}\\")
        p.writes.removeAll()
        p.feed("\u{1B}P+q00\u{1B}\\")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}P0+r\u{1B}\\")
    }

    func testDSRThemeAndVisibility() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?996n")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?997;1n")
        p.writes.removeAll()
        p.feed("\u{1B}[?998n")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?999;1n")
    }

    func testSizeReportUnderParseLock() {
        let session = TerminalSession(cols: 10, rows: 5, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0)
        var replies: [UInt8] = []
        session.parser.ptyWriter = { replies.append(contentsOf: $0) }
        session.lock.lock()
        session.parser.feed("\u{1B}[18t\u{1B}[14t")
        session.lock.unlock()
        let text = String(bytes: replies, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\u{1B}[8;5;10t"), text)
        XCTAssertTrue(text.contains("\u{1B}[4;80;80t"), text)
    }

    func testDECSCUSR() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[3 q")
        XCTAssertEqual(s.cursorStyle, 3)
        p.feed("\u{1B}[0 q")
        XCTAssertEqual(s.cursorStyle, 0)
        p.feed("\u{1B}[6 q")
        XCTAssertEqual(s.cursorStyle, 6)
    }

    func testUTF8Scalar() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("é")
        XCTAssertEqual(s.glyph(0, 0), 0xE9)
    }

    func testScanPrintableStopsAtESC() {
        let bytes: [UInt8] = [0x41, 0x42, 0x1B, 0x43]
        XCTAssertEqual(jt_scan_printable_ascii(bytes, bytes.count), 2)
        XCTAssertEqual(jt_scan_until_c0(bytes, bytes.count), 2)
        XCTAssertEqual(jt_scan_first_esc(bytes, bytes.count), 2)
    }

    func testSmacsQIsHline() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}(0q")
        XCTAssertEqual(s.glyph(0, 0), 0x2500)
        p.feed("\u{1B}(Bq")
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "q")))
    }

    func testSOandSI() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{0E}x")
        XCTAssertEqual(s.glyph(0, 0), 0x2502)
        p.feed("\u{0F}x")
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "x")))
    }

    func testSGRIndexedAndBold() {
        let s = Screen(cols: 20, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[31;1mA")
        XCTAssertEqual(s.penFG, PackedColor.indexed(1))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_BOLD), UInt16(ATTR_BOLD))
        XCTAssertEqual(s.glyph(0, 0), UInt32(UInt8(ascii: "A")))
        p.feed("\u{1B}[91mB")
        XCTAssertEqual(s.penFG, PackedColor.indexed(9))
    }

    func testSGRTruecolorAndMixed() {
        let s = Screen(cols: 20, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[38;5;196;48;2;1;2;3mX")
        XCTAssertEqual(s.penFG, PackedColor.indexed(196))
        XCTAssertEqual(s.penBG, PackedColor.rgb(r: 1, g: 2, b: 3))
        p.feed("\u{1B}[38:2::10:20:30m")
        XCTAssertEqual(s.penFG, PackedColor.rgb(r: 10, g: 20, b: 30))
    }

    func testSGR21DoubleUnderline() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[31;21m")
        XCTAssertEqual(s.penFG, PackedColor.indexed(1))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_DOUBLE))
    }

    func testSGRSmulxStrikeOverlineBlink() {
        let s = Screen(cols: 10, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[4:3m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_CURLY))
        p.feed("\u{1B}[4:4m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_DOTTED))
        p.feed("\u{1B}[4:5m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), UInt16(UL_DASHED))
        p.feed("\u{1B}[9;53;5m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_STRIKETHROUGH), UInt16(ATTR_STRIKETHROUGH))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_OVERLINE), UInt16(ATTR_OVERLINE))
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_BLINK), UInt16(ATTR_BLINK))
        p.feed("\u{1B}[24;29;55;25m")
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_UL_MASK), 0)
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_STRIKETHROUGH), 0)
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_OVERLINE), 0)
        XCTAssertEqual(s.penAttrs & UInt16(ATTR_BLINK), 0)
    }

    func testCUP() {
        let s = Screen(cols: 20, rows: 10, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[5;8H")
        XCTAssertEqual(s.cursorY, 4)
        XCTAssertEqual(s.cursorX, 7)
    }

    func testCSICNLAndCPL() {
        let s = Screen(cols: 20, rows: 10, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[5;5H\u{1B}[E")
        XCTAssertEqual(s.cursorY, 5)
        XCTAssertEqual(s.cursorX, 0)
        p.feed("\u{1B}[2F")
        XCTAssertEqual(s.cursorY, 3)
        XCTAssertEqual(s.cursorX, 0)
    }

    func testCSICHTAndCBTCount() {
        let s = Screen(cols: 40, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[I")
        XCTAssertEqual(s.cursorX, 8)
        p.feed("\u{1B}[2I")
        XCTAssertEqual(s.cursorX, 24)
        p.feed("\u{1B}[2Z")
        XCTAssertEqual(s.cursorX, 8)
    }

    func testCSIREP() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("A\u{1B}[b")
        XCTAssertEqual(s.plainString(), "AA")
        p.feed("\u{1B}[3b")
        XCTAssertEqual(s.plainString(), "AAAAA")
        p.feed("\u{1B}c")
        p.feed("\u{1B}[5b")
        XCTAssertEqual(s.plainString(), "")
        p.feed("e\u{0301}\u{1B}[b")
        XCTAssertEqual(s.cursorX, 2)
        XCTAssertEqual(s.glyph(1, 0), UInt32(UInt8(ascii: "e")))
        let c0 = s.row(0)[0]
        XCTAssertEqual(c0.contentKind, CONTENT_GRAPHEME)
        var n: UInt16 = 0
        let cps = jt_grapheme_get(s.implPtr, c0.contentPayload, &n)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(cps?[0], UInt32(UInt8(ascii: "e")))
        XCTAssertEqual(cps?[1], 0x0301)
    }

    func testCSICursorAliases() {
        let s = Screen(cols: 20, rows: 10, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[5;5H\u{1B}[k")
        XCTAssertEqual(s.cursorY, 3)
        XCTAssertEqual(s.cursorX, 4)
        p.feed("\u{1B}[a")
        XCTAssertEqual(s.cursorX, 5)
        p.feed("\u{1B}[j")
        XCTAssertEqual(s.cursorX, 4)
        p.feed("\u{1B}[e")
        XCTAssertEqual(s.cursorY, 4)
        p.feed("\u{1B}[3`")
        XCTAssertEqual(s.cursorX, 2)
    }

    func testCSISCAndRC() {
        let s = Screen(cols: 20, rows: 10, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[4;6H\u{1B}[s\u{1B}[1;1H\u{1B}[u")
        XCTAssertEqual(s.cursorY, 3)
        XCTAssertEqual(s.cursorX, 5)
        p.feed("\u{1B}[?1048h\u{1B}[10;10H\u{1B}[?1048l")
        XCTAssertEqual(s.cursorY, 3)
        XCTAssertEqual(s.cursorX, 5)
        p.feed("\u{1B}[H")
        p.feed("B\u{1B}[?u\u{1B}[>u\u{1B}[<u\u{1B}[=u")
        XCTAssertEqual(s.plainString().prefix(1), "B")
        XCTAssertEqual(s.cursorX, 1)
        XCTAssertEqual(s.cursorY, 0)
    }

    func testDECALN() {
        let s = Screen(cols: 4, rows: 2, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[2;3r\u{1B}[2;2H\u{1B}#8")
        XCTAssertEqual(s.cursorY, 0)
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.scrollTop, 0)
        XCTAssertEqual(s.scrollBottom, 1)
        XCTAssertEqual(s.plainString(), "EEEE\nEEEE")
    }

    func testReverseWrap() {
        let s = Screen(cols: 5, rows: 5, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("ABCDE\u{08}")
        XCTAssertEqual(s.cursorY, 0)
        XCTAssertEqual(s.cursorX, 3)
        XCTAssertFalse(s.pendingWrap)
        p.feed("\u{1B}c\u{1B}[?45hABCDE\u{08}X")
        XCTAssertEqual(s.plainString(), "ABCDX")
        p.feed("\u{1B}c\u{1B}[?45hABCDE\r\n1\u{1B}[2DX")
        XCTAssertEqual(s.plainString(), "ABCDE\nX")
        p.feed("\u{1B}c\u{1B}[?45hABCDE1\u{1B}[2DX")
        XCTAssertEqual(s.plainString(), "ABCDX\n1")
        p.feed("\u{1B}c\u{1B}[?45h\u{1B}[2;1H\u{08}")
        XCTAssertEqual(s.cursorY, 1)
        XCTAssertEqual(s.cursorX, 0)
        p.feed("\u{1B}c\u{1B}[3;r\u{1B}[?45h\u{08}X")
        XCTAssertEqual(s.plainString(), "\n\nX")
        p.writes.removeAll()
        p.feed("\u{1B}[?45$p")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?45;1$y")
    }

    func testReverseWrapExtended() {
        let s = Screen(cols: 5, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?1045hABCDE\r\n1\u{1B}[2DX")
        XCTAssertEqual(s.plainString(), "ABCDX\n1")
        p.feed("\u{1B}c\u{1B}[?1045hABCDE\r\n1\u{1B}[7DX")
        XCTAssertEqual(s.plainString(), "ABCDE\n1\n    X")
        p.feed("\u{1B}c\u{1B}[?45h\u{1B}[?1045hABCDE\r\n1\u{1B}[7DX")
        XCTAssertEqual(s.plainString(), "ABCDE\n1\n    X")
        p.feed("\u{1B}c\u{1B}[?1045h\u{1B}[2;1H\u{08}")
        XCTAssertEqual(s.cursorY, 0)
        XCTAssertEqual(s.cursorX, 4)
    }

    func testXTSAVEWrap() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[?7l\u{1B}[?7s\u{1B}[?7h\u{1B}[?7r")
        XCTAssertFalse(s.autoWrap)
        p.feed("\u{1B}[20hxy\n")
        XCTAssertEqual(s.cursorX, 0)
        p.feed("\u{1B}c")
        XCTAssertTrue(s.cursorVisible)
        XCTAssertTrue(s.autoWrap)
        p.feed("\u{1B}[?25r\u{1B}[?7r")
        XCTAssertTrue(s.cursorVisible)
        XCTAssertTrue(s.autoWrap)
        p.feed("\u{1B}[?25l\u{1B}[?25r")
        XCTAssertFalse(s.cursorVisible)
        p.feed("\u{1B}[?25h\u{1B}[?25s\u{1B}[?25l\u{1B}[?25r")
        XCTAssertTrue(s.cursorVisible)
    }

    func testRISClearsInbandAndXtsave() {
        let s = Screen(cols: 10, rows: 3, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        var kinds: [Int32] = []
        p.onSizeReport = { kinds.append($0) }
        p.feed("\u{1B}[?7l\u{1B}[?7s\u{1B}[?2048h\u{1B}[?2031h\u{1B}[?2033h")
        XCTAssertEqual(kinds, [48])
        XCTAssertFalse(s.autoWrap)
        p.feed("\u{1B}c")
        kinds.removeAll()
        p.writes.removeAll()
        XCTAssertTrue(s.autoWrap)
        p.feed("\u{1B}[?7r")
        XCTAssertTrue(s.autoWrap)
        p.feed("\u{1B}[?2048$p\u{1B}[?2031$p\u{1B}[?2033$p")
        XCTAssertEqual(
            String(bytes: p.writes, encoding: .utf8),
            "\u{1B}[?2048;2$y\u{1B}[?2031;2$y\u{1B}[?2033;2$y"
        )
        p.feed("\u{1B}[?2048h")
        XCTAssertEqual(kinds, [48])
    }

    func testInbandSizeReport() {
        let session = TerminalSession(cols: 10, rows: 5, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0)
        var replies: [UInt8] = []
        session.parser.ptyWriter = { replies.append(contentsOf: $0) }
        session.lock.lock()
        session.parser.feed("\u{1B}[?2048h")
        session.lock.unlock()
        let enable = String(bytes: replies, encoding: .utf8) ?? ""
        XCTAssertEqual(enable, "\u{1B}[48;5;10;80;80t")
        replies.removeAll()
        session.lock.lock()
        session.parser.feed("\u{1B}[?2048h")
        session.lock.unlock()
        XCTAssertEqual(String(bytes: replies, encoding: .utf8), "\u{1B}[48;5;10;80;80t")
        replies.removeAll()
        session.setWinsize(cols: 12, rows: 6)
        XCTAssertEqual(String(bytes: replies, encoding: .utf8), "\u{1B}[48;6;12;96;96t")
        replies.removeAll()
        session.lock.lock()
        session.parser.feed("\u{1B}c")
        session.lock.unlock()
        session.setWinsize(cols: 14, rows: 7)
        XCTAssertEqual(String(bytes: replies, encoding: .utf8), "")
    }

    func testTitleStackNoReport() {
        final class Titles: @unchecked Sendable {
            var items: [String] = []
        }
        let session = TerminalSession(cols: 10, rows: 5, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0)
        var replies: [UInt8] = []
        let titles = Titles()
        session.parser.ptyWriter = { replies.append(contentsOf: $0) }
        session.onTitle = { titles.items.append($0) }
        session.lock.lock()
        session.parser.feed("\u{1B}]0;hello\u{07}")
        session.parser.feed("\u{1B}[22;0t")
        session.parser.feed("\u{1B}]0;world\u{07}")
        session.parser.feed("\u{1B}[23;0t")
        session.parser.feed("\u{1B}[21t")
        session.parser.feed("\u{1B}[22t")
        session.lock.unlock()
        let exp = expectation(description: "title")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(String(bytes: replies, encoding: .utf8) ?? "", "")
        XCTAssertEqual(titles.items, ["hello", "world", "hello"])
    }
}
