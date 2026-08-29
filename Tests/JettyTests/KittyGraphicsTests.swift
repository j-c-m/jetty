import CVt
import XCTest
@testable import Jetty

final class KittyGraphicsTests: XCTestCase {
    private func apc(_ body: String) -> String {
        "\u{1B}_G\(body)\u{1B}\\"
    }

    private func b64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    func testCellStill16() {
        XCTAssertEqual(MemoryLayout<CVt.Cell>.size, 16)
    }

    func testNonGApcDoesNotPrintOrReply() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}_hello\u{1B}\\X")
        XCTAssertEqual(s.plainString(), "X")
        XCTAssertEqual(p.writes, [])
    }

    func testQueryThenDA1() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;\(b64([255, 0, 0]))"))
        p.feed("\u{1B}[c")
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertTrue(out.contains("\u{1B}[?1;2c"), out)
        XCTAssertTrue(out.hasPrefix("\u{1B}_G"), out)
        XCTAssertLessThan(out.firstIndex(of: "c") ?? out.endIndex, out.endIndex)
        let okAt = out.range(of: "OK")?.lowerBound
        let daAt = out.range(of: "[?1;2c")?.lowerBound
        XCTAssertNotNil(okAt)
        XCTAssertNotNil(daAt)
        if let okAt, let daAt {
            XCTAssertLessThan(okAt, daAt)
        }
    }

    func testGraphicsOffNoQueryReply() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setKittyGraphics(false)
        let p = Parser()
        p.screen = s
        p.feed(apc("i=31,s=1,v=1,a=q,t=d,f=24;\(b64([255, 0, 0]))"))
        p.feed("\u{1B}[c")
        XCTAssertEqual(String(bytes: p.writes, encoding: .utf8), "\u{1B}[?1;2c")
    }

    func testCursorMovesToRightOfLastRow() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 3, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=3,r=4,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 3)
        XCTAssertEqual(s.cursorY, 3)
        XCTAssertFalse(s.pendingWrap)
    }

    func testFullWidthPutWrapsToLineAfterImage() {
        let s = Screen(cols: 10, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 4, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=10,r=3,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 3)
    }

    func testTallPutAtBottomScrollsPromptBelow() {
        let s = Screen(cols: 10, rows: 5, scrollbackCapRows: 32)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[5;1H")
        XCTAssertEqual(s.cursorY, 4)
        let rgb = [UInt8](repeating: 5, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=10,r=8,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 4)
        XCTAssertGreaterThan(s.scrollbackCount, 0)
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
    }

    func testC1LeavesCursor() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[3;5H")
        let rgb = [UInt8](repeating: 6, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=4,r=3,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.cursorX, 4)
        XCTAssertEqual(s.cursorY, 2)
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testImplicitIdDoesNotReply() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(p.writes, [])
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testImageNumberRepliesAssignedId() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,I=13,t=d,C=1;\(b64(rgb))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("I=13"), out)
        XCTAssertTrue(out.contains("i="), out)
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertFalse(out.contains("i=13;"), out)
    }

    func testRGBPutDoesNotFillCells() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        var rgb = [UInt8](repeating: 0, count: 12)
        rgb[0] = 255
        p.feed(apc("a=T,f=24,s=2,v=2,i=7,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        XCTAssertEqual(s.imgHistN, 0)
        XCTAssertEqual(s.plainString().trimmingCharacters(in: .whitespacesAndNewlines), "")
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("i=7"), out)
        XCTAssertTrue(out.contains("OK"), out)
    }

    func testRetransmitDropsOldPlacement() {
        let s = Screen(cols: 20, rows: 5, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 128, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=3,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=t,f=24,s=2,v=2,i=3,t=d;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testIndexMovesToHistoryWithoutWalkingIdle() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 1, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=9,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        for _ in 0..<8 {
            p.feed("\n")
        }
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
        p.feed(String(repeating: "y\n", count: 200))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
    }

    func testED2ClearsLiveDest() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[7;1H")
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=4,r=10,t=d,C=1;\(b64(rgb))"))
        XCTAssertGreaterThan(s.imgLiveN, 0)
        p.feed("\n\n")
        p.feed("\u{1B}[2J")
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testQuietSuppressesOK() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 2, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=5,q=1,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(p.writes, [])
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testU1VirtualPutDoesNotPinOrMoveCursor() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[2;3H")
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,U=1,i=42,s=2,v=2,f=24,c=2,r=2,t=d;\(b64(rgb))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertFalse(out.contains("ENOTSUP"), out)
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 0)
        XCTAssertEqual(s.imgVirtualN, 1)
        XCTAssertEqual(s.cursorX, 2)
        XCTAssertEqual(s.cursorY, 1)
    }

    func testRelativePutOffsetsFromParentPin() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=2,r=1,t=d,C=1;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=p,i=2,P=1,H=3,V=1,c=2,r=1,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertFalse(out.contains("ENOTSUP"), out)
        XCTAssertEqual(s.imgLiveN, 1)
        XCTAssertEqual(s.imgRelativeN, 1)
        XCTAssertEqual(s.cursorX, 0)
        XCTAssertEqual(s.cursorY, 0)
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 8)
        let n = snaps.withUnsafeMutableBufferPointer { buf in
            let pins = jt_img_snapshot(s.implPtr, 0, 8, 8, 16, buf.baseAddress!, 8)
            let rel = jt_img_relative_scan(
                s.implPtr, nil, 20, 8, 0, 8, 16,
                buf.baseAddress! + Int(pins), 8 - pins
            )
            return pins + rel
        }
        XCTAssertEqual(n, 2)
        let parent = snaps[0].image_id == 1 ? snaps[0] : snaps[1]
        let child = snaps[0].image_id == 2 ? snaps[0] : snaps[1]
        XCTAssertEqual(parent.image_id, 1)
        XCTAssertEqual(child.image_id, 2)
        XCTAssertEqual(child.ox, parent.ox + 3 * 8)
        XCTAssertEqual(child.oy, parent.oy + 1 * 16)
    }

    func testRelativeMissingParent() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=p,i=2,P=99,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("ENOPARENT"), out)
        XCTAssertEqual(s.imgRelativeN, 0)
    }

    func testRelativeVirtualParentSparseOrigin() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,U=1,i=1,s=2,v=2,f=24,c=2,r=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=p,i=2,P=1,H=0,V=0,c=1,r=1,C=1,q=2"))
        XCTAssertEqual(s.imgVirtualN, 1)
        XCTAssertEqual(s.imgRelativeN, 1)
        p.feed("\u{1B}[1;6H\u{1B}[38;5;1m\u{10EEEE}")
        p.feed("\u{1B}[2;1H\u{10EEEE}\u{1B}[39m")
        var paint = [Cell](repeating: .empty, count: s.cols * s.rows)
        paint.withUnsafeMutableBufferPointer { dest in
            s.blitLiveGrid(to: dest.baseAddress!)
        }
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 8)
        let n = paint.withUnsafeBufferPointer { cellBuf in
            snaps.withUnsafeMutableBufferPointer { buf in
                jt_img_relative_scan(
                    s.implPtr, cellBuf.baseAddress!, 10, 4, 0, 8, 16,
                    buf.baseAddress!, 8
                )
            }
        }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(snaps[0].image_id, 2)
        XCTAssertEqual(snaps[0].ox, 0)
        XCTAssertEqual(snaps[0].oy, 0)
    }

    func testRelativeVirtualParentRejected() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,U=1,i=1,s=2,v=2,f=24,c=2,r=2,t=d,q=2;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=p,U=1,i=1,P=1,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL"), out)
        XCTAssertTrue(out.contains("virtual"), out)
    }

    func testRelativeSelfParent() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,p=7,t=d,C=1;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=p,i=1,p=7,P=1,Q=7,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL"), out)
        XCTAssertTrue(out.contains("parent"), out)
    }

    func testRelativeOrphanedWhenParentDeleted() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=2,r=1,t=d,C=1,q=2;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=p,i=2,P=1,H=1,C=1,q=2"))
        XCTAssertEqual(s.imgRelativeN, 1)
        p.feed(apc("a=d,d=a"))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgRelativeN, 0)
    }

    func testRelativeIdentityDeleteOrphans() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,p=7,t=d,C=1,q=2;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=p,i=2,P=1,Q=7,H=1,C=1,q=2"))
        XCTAssertEqual(s.imgRelativeN, 1)
        p.feed(apc("a=d,d=i,i=1"))
        XCTAssertEqual(s.imgRelativeN, 0)
    }

    func testDeleteALeavesRelativeWhenParentInHistory() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 3, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,t=d,C=1,q=2;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=p,i=2,P=1,H=1,C=1,q=2"))
        p.feed(String(repeating: "y\n", count: 20))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgHistN, 1)
        XCTAssertEqual(s.imgRelativeN, 1)
        p.feed(apc("a=d,d=a"))
        XCTAssertEqual(s.imgHistN, 1)
        XCTAssertEqual(s.imgRelativeN, 1)
    }

    func testRelativeCycle() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,p=1,t=d,C=1,q=2;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=p,i=2,p=2,P=1,Q=1,C=1,q=2"))
        XCTAssertEqual(s.imgRelativeN, 1)
        p.writes.removeAll()
        p.feed(apc("a=p,i=1,p=1,P=2,Q=2,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("ECYCLE"), out)
        XCTAssertEqual(s.imgRelativeN, 1)
    }

    func testRelativeTooDeep() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,p=1,t=d,C=1,q=2;\(b64(rgb))"))
        for n in 2...9 {
            p.feed(apc("a=t,f=24,s=2,v=2,i=\(n),t=d,q=2;\(b64(rgb))"))
            p.feed(apc("a=p,i=\(n),p=\(n),P=\(n - 1),Q=\(n - 1),C=1,q=2"))
        }
        XCTAssertEqual(s.imgRelativeN, 8)
        p.feed(apc("a=t,f=24,s=2,v=2,i=10,t=d,q=2;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=p,i=10,p=10,P=9,Q=9,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("ETOODEEP"), out)
        XCTAssertEqual(s.imgRelativeN, 8)
    }

    func testRelativeNegativeOffset() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed("\u{1B}[1;4H")
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=2,r=1,t=d,C=1;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=p,i=2,P=1,H=-1,V=0,c=2,r=1,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 8)
        let n = snaps.withUnsafeMutableBufferPointer { buf in
            let pins = jt_img_snapshot(s.implPtr, 0, 8, 8, 16, buf.baseAddress!, 8)
            let rel = jt_img_relative_scan(
                s.implPtr, nil, 20, 8, 0, 8, 16,
                buf.baseAddress! + Int(pins), 8 - pins
            )
            return pins + rel
        }
        XCTAssertEqual(n, 2)
        let parent = snaps[0].image_id == 1 ? snaps[0] : snaps[1]
        let child = snaps[0].image_id == 2 ? snaps[0] : snaps[1]
        XCTAssertEqual(child.ox, parent.ox - 8)
    }

    func testRelativeIdleYnDoesNotWalk() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 3, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,t=d,C=1,q=2;\(b64(rgb))"))
        p.feed(apc("a=t,f=24,s=2,v=2,i=2,t=d,q=2;\(b64(rgb))"))
        p.feed(apc("a=p,i=2,P=1,H=1,C=1,q=2"))
        XCTAssertEqual(s.imgLiveN, 1)
        XCTAssertEqual(s.imgRelativeN, 1)
        p.feed(String(repeating: "y\n", count: 20))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgRelativeN, 1)
        XCTAssertEqual(s.poolCells, 0)
    }

    func testDeleteALeavesVirtualDeleteIRemoves() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,U=1,i=42,s=2,v=2,f=24,c=2,r=2,t=d,q=2;\(b64(rgb))"))
        XCTAssertEqual(s.imgVirtualN, 1)
        p.feed(apc("a=d,d=a"))
        XCTAssertEqual(s.imgVirtualN, 1)
        p.feed(apc("a=d,d=i,i=42"))
        XCTAssertEqual(s.imgVirtualN, 0)
    }

    func testPlaceholder2x2IndexedFg() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 7, count: 12)
        p.feed(apc("a=T,U=1,i=42,s=2,v=2,f=24,c=2,r=2,t=d,q=2;\(b64(rgb))"))
        XCTAssertEqual(s.imgVirtualN, 1)
        p.feed("\u{1B}[1;1H\u{1B}[38;5;42m")
        p.feed("\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}\r\n")
        p.feed("\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}\u{030D}\u{030D}\u{1B}[39m")
        var paint = [Cell](repeating: .empty, count: s.cols * s.rows)
        paint.withUnsafeMutableBufferPointer { dest in
            s.blitLiveGrid(to: dest.baseAddress!)
        }
        var hide = [UInt8](repeating: 0, count: s.cols * s.rows)
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 8)
        let n = hide.withUnsafeMutableBufferPointer { hideBuf in
            paint.withUnsafeBufferPointer { cellBuf in
                snaps.withUnsafeMutableBufferPointer { snapBuf in
                    jt_img_placeholder_scan(
                        s.implPtr,
                        cellBuf.baseAddress!,
                        Int32(s.cols),
                        Int32(s.rows),
                        8,
                        16,
                        hideBuf.baseAddress!,
                        snapBuf.baseAddress!,
                        8
                    )
                }
            }
        }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(hide[0], 1)
        XCTAssertEqual(hide[1], 1)
        XCTAssertEqual(hide[s.cols], 1)
        XCTAssertEqual(hide[s.cols + 1], 1)
        XCTAssertEqual(snaps[0].image_id, 42)
        XCTAssertEqual(snaps[1].image_id, 42)
        XCTAssertGreaterThan(snaps[0].sx, 0)
        XCTAssertGreaterThan(snaps[1].sx, 0)
        XCTAssertEqual(s.row(0)[0].contentKind, CONTENT_GRAPHEME)
    }

    func testBelowBgSnapshotKeepsCellDestAndZ() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 9, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,c=12,r=4,z=-1073741825,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 4)
        let n = snaps.withUnsafeMutableBufferPointer { buf in
            jt_img_snapshot(s.implPtr, 0, 8, 8, 16, buf.baseAddress!, 4)
        }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(snaps[0].z, -1_073_741_825)
        XCTAssertEqual(snaps[0].sx, 12 * 8)
        XCTAssertEqual(snaps[0].sy, 4 * 16)
    }

    func testDim10000Stores10001Rejected() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 1, count: 10000 * 3)
        p.feed(apc("a=t,f=24,s=10000,v=1,i=1,t=d,q=2;\(b64(rgb))"))
        let st = jt_img_active(s.implPtr)
        XCTAssertNotNil(st)
        XCTAssertNotNil(jt_img_find(st, 1))
        p.writes.removeAll()
        p.feed(apc("a=t,f=24,s=10001,v=1,i=2,t=d;\(b64([1, 2, 3]))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL"), out)
        XCTAssertNil(jt_img_find(st, 2))
    }

    func testUsageHintNMarksTransientAndEvictsFirst() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let pix = b64([1, 2, 3])
        for i in 1...255 {
            p.feed(apc("a=t,f=24,s=1,v=1,i=\(i),t=d,q=2,N=0;\(pix)"))
        }
        p.feed(apc("a=t,f=24,s=1,v=1,i=256,t=d,q=2,N=1;\(pix)"))
        let st = jt_img_active(s.implPtr)
        XCTAssertEqual(jt_img_find(st, 256)?.pointee.transient, 1)
        XCTAssertEqual(jt_img_find(st, 1)?.pointee.transient, 0)
        p.feed(apc("a=t,f=24,s=1,v=1,i=257,t=d,q=2,N=0;\(pix)"))
        XCTAssertNil(jt_img_find(st, 256))
        XCTAssertNotNil(jt_img_find(st, 1))
        XCTAssertNotNil(jt_img_find(st, 257))
    }

    func testVirtualIdleYnDoesNotInternGrapheme() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 3, count: 12)
        p.feed(apc("a=T,U=1,i=9,s=2,v=2,f=24,c=2,r=2,t=d,q=2;\(b64(rgb))"))
        XCTAssertEqual(s.imgVirtualN, 1)
        XCTAssertEqual(s.poolCells, 0)
        p.feed(String(repeating: "y\n", count: 200))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertEqual(s.imgVirtualN, 1)
        XCTAssertEqual(s.poolCells, 0)
    }

    func testPasswdFileRefused() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        let p = Parser()
        p.screen = s
        let path = Array("/etc/passwd".utf8)
        p.feed(apc("a=t,f=24,s=1,v=1,i=8,t=f;\(b64(path))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL") || out.contains("ENOENT") || !out.contains("OK") || out.contains("EINVAL"), out)
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testPNG1x1() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let png = Self.png1x1Red
        p.feed(apc("a=T,f=100,i=11,t=d,C=1;\(b64(png))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testDeletePHitsCoveredNonOriginCell() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,c=4,r=6,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=p,x=2,y=4"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testDeleteIWithPlacementId() {
        let s = Screen(cols: 20, rows: 8, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=t,f=24,s=2,v=2,i=4,t=d;\(b64(rgb))"))
        p.feed("\u{1B}[1;1H")
        p.feed(apc("a=p,i=4,p=1,c=2,r=1,C=1"))
        p.feed("\u{1B}[2;1H")
        p.feed(apc("a=p,i=4,p=2,c=2,r=1,C=1"))
        XCTAssertEqual(s.imgLiveN, 2)
        p.feed(apc("a=d,d=i,i=4,p=1"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=I,i=4"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testDeleteRangeInvertedMatchesNothing() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=5,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=r,x=9,y=1"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=r,x=5,y=5"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testDeleteColumnAndZ() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,i=6,c=3,r=2,z=-1,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=z,z=0"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=x,x=2"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testImageNumberNewest() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 8, count: 12)
        p.feed(apc("a=T,f=24,s=2,v=2,I=3,t=d,C=1;\(b64(rgb))"))
        p.writes.removeAll()
        p.feed(apc("a=T,f=24,s=2,v=2,I=3,t=d,C=1;\(b64(rgb))"))
        XCTAssertEqual(s.imgLiveN, 2)
        p.feed(apc("a=d,d=N,I=3"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=N,I=3"))
        XCTAssertEqual(s.imgLiveN, 0)
    }

    func testChunkedRGB() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        let rgb = [UInt8](repeating: 7, count: 12)
        let enc = b64(rgb)
        let mid = enc.index(enc.startIndex, offsetBy: 8)
        p.feed(apc("a=T,f=24,s=2,v=2,i=12,t=d,m=1,C=1;\(enc[..<mid])"))
        XCTAssertEqual(s.imgLiveN, 0)
        p.feed(apc("m=0;\(enc[mid...])"))
        XCTAssertEqual(s.imgLiveN, 1)
    }

    func testAnimFrameAppendAndClientSwitch() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1;\(b64([255, 0, 0]))"))
        p.writes.removeAll()
        p.feed(apc("a=f,f=24,s=1,v=1,i=1,t=d;\(b64([0, 255, 0]))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertTrue(out.contains("r=2"), out)
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 2)
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 1)
        XCTAssertEqual(firstPixel(s)?.0, 255)
        p.writes.removeAll()
        p.feed(apc("a=a,i=1,c=2"))
        XCTAssertEqual(p.writes, [])
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 2)
        XCTAssertEqual(firstPixel(s)?.1, 255)
        p.feed(apc("a=a,i=1,c=1"))
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 1)
        XCTAssertEqual(firstPixel(s)?.0, 255)
    }

    func testAnimMissingImage() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=f,f=24,s=1,v=1,i=99,t=d;\(b64([1, 2, 3]))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("ENOENT"), out)
    }

    func testAnimIdAndNumberExclusive() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=f,i=1,I=2,s=1,v=1,t=d,f=24;\(b64([1, 2, 3]))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL"), out)
        XCTAssertTrue(out.contains("mutually exclusive"), out)
    }

    func testAnimTickAdvances() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        p.feed(apc("a=f,f=24,s=1,v=1,i=1,z=10,t=d,q=2;\(b64([0, 255, 0]))"))
        p.feed(apc("a=a,i=1,r=1,z=10"))
        p.feed(apc("a=a,i=1,s=3"))
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 1)
        XCTAssertEqual(jt_img_anim_tick(s.implPtr, 1), 10)
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 1)
        XCTAssertEqual(jt_img_anim_tick(s.implPtr, 11), 10)
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 2)
        XCTAssertEqual(firstPixel(s)?.1, 255)
    }

    func testAnimComposeOverwrite() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        p.feed(apc("a=f,f=24,s=1,v=1,i=1,t=d,q=2;\(b64([0, 255, 0]))"))
        p.writes.removeAll()
        p.feed(apc("a=c,i=1,r=2,c=1,C=1"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertEqual(firstPixel(s)?.1, 255)
    }

    func testAnimDeleteFrame() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        p.feed(apc("a=f,f=24,s=1,v=1,i=1,t=d,q=2;\(b64([0, 255, 0]))"))
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 2)
        p.feed(apc("a=d,d=f,i=1,r=2"))
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 1)
        XCTAssertEqual(firstPixel(s)?.0, 255)
    }

    func testAnimDeleteRootPromotes() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        p.feed(apc("a=f,f=24,s=1,v=1,i=1,t=d,q=2;\(b64([0, 255, 0]))"))
        p.feed(apc("a=d,d=f,i=1,r=1"))
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 1)
        XCTAssertEqual(firstPixel(s)?.1, 255)
    }

    func testAnimUppercaseFWithoutFramesDeletesImage() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        XCTAssertEqual(s.imgLiveN, 1)
        p.feed(apc("a=d,d=F,i=1"))
        XCTAssertEqual(s.imgLiveN, 0)
        XCTAssertNil(jt_img_find(jt_img_active(s.implPtr), 1))
    }

    func testAnimIdleYnDoesNotTick() {
        let s = Screen(cols: 8, rows: 4, scrollbackCapRows: 16)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        p.feed(apc("a=f,f=24,s=1,v=1,i=1,z=10,t=d,q=2;\(b64([0, 255, 0]))"))
        p.feed(apc("a=a,i=1,r=1,z=10"))
        p.feed(apc("a=a,i=1,s=3"))
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 1)
        p.feed(String(repeating: "y\n", count: 20))
        XCTAssertEqual(jt_img_anim_current(s.implPtr, 1), 1)
        XCTAssertEqual(s.poolCells, 0)
    }

    func testAnimFrameTooBig() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=1,v=1,i=1,t=d,C=1,q=2;\(b64([255, 0, 0]))"))
        p.writes.removeAll()
        let rgb = [UInt8](repeating: 1, count: 27)
        p.feed(apc("a=f,f=24,s=3,v=3,i=1,t=d;\(b64(rgb))"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("EINVAL"), out)
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 1)
    }

    func testAnimChunkedFrame() {
        let s = Screen(cols: 10, rows: 4, scrollbackCapRows: 0)
        s.setCellPx(width: 8, height: 16)
        let p = Parser()
        p.screen = s
        p.feed(apc("a=T,f=24,s=2,v=2,i=1,t=d,C=1,q=2;\(b64([UInt8](repeating: 9, count: 12)))"))
        let rgb = [UInt8](repeating: 7, count: 12)
        let enc = b64(rgb)
        let mid = enc.index(enc.startIndex, offsetBy: 8)
        p.feed(apc("a=f,f=24,s=2,v=2,i=1,t=d,m=1;\(enc[..<mid])"))
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 1)
        p.writes.removeAll()
        p.feed(apc("a=f,m=0;\(enc[mid...])"))
        let out = String(bytes: p.writes, encoding: .utf8) ?? ""
        XCTAssertTrue(out.contains("OK"), out)
        XCTAssertEqual(jt_img_anim_frame_count(s.implPtr, 1), 2)
    }

    private func firstPixel(_ s: Screen) -> (UInt8, UInt8, UInt8, UInt8)? {
        var snaps = [jt_img_snap](repeating: jt_img_snap(), count: 4)
        let n = snaps.withUnsafeMutableBufferPointer { buf in
            jt_img_snapshot(s.implPtr, 0, Int32(s.rows), 8, 16, buf.baseAddress!, 4)
        }
        guard n > 0, let rgba = snaps[0].rgba else { return nil }
        return (rgba[0], rgba[1], rgba[2], rgba[3])
    }

    /// 1×1 opaque red PNG.
    private static let png1x1Red: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE,
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    ]
}
