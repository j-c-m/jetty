import AppKit
import Foundation
import XCTest
@testable import Jetty

final class Osc5522Tests: XCTestCase {
    private func parse(_ meta: String, payload: String = "") -> Osc5522.ParseResult {
        Osc5522.ParseResult.parse(meta: Array(meta.utf8), payload: Array(payload.utf8))
    }

    private func packet(_ meta: String, payload: String = "") -> Osc5522.Packet {
        guard case .packet(let p) = parse(meta, payload: payload) else {
            XCTFail("expected packet for \(meta)")
            return Osc5522.Packet(
                op: .read, primary: false, id: "", mime: "", pw: "", name: "", payload: []
            )
        }
        return p
    }

    func testMetadataDropVsInvalid() {
        XCTAssertEqual(parse(""), .drop)
        XCTAssertEqual(parse("type=read:bare"), .drop)
        XCTAssertEqual(parse("bare:type=read"), .drop)
        XCTAssertEqual(parse("loc=primary"), .drop)
        XCTAssertEqual(parse("type=bobr"), .drop)
        XCTAssertEqual(parse("type="), .drop)
        XCTAssertEqual(parse("type=wdata:mime=!!!"), .invalid(op: .wdata, id: ""))
        XCTAssertEqual(parse("type=read:mime=!!!"), .invalid(op: .read, id: ""))
        XCTAssertEqual(
            parse("type=wdata:id=w1:mime=!!!"),
            .invalid(op: .wdata, id: "w1")
        )
    }

    func testLastKeyWinsAndUnknownKeys() {
        XCTAssertEqual(packet("type=bobr:type=read").op, .read)
        XCTAssertEqual(parse("type=read:type=bobr"), .drop)
        XCTAssertEqual(packet("type=read:bobr=kurwa").op, .read)
    }

    func testLocAndIdSanitize() {
        XCTAssertTrue(packet("type=read:loc=primary").primary)
        XCTAssertFalse(packet("type=read:loc=bobr").primary)
        XCTAssertFalse(packet("type=read").primary)
        XCTAssertEqual(packet("type=read:id=abc-123_x.Y+z").id, "abc-123_x.Y+z")
        XCTAssertEqual(packet("type=read:id=*4 2*").id, "42")
        let long = "type=read:id=" + String(repeating: "a", count: Osc5522.maxIdLen + 100)
        XCTAssertEqual(packet(long).id.count, Osc5522.maxIdLen)
        XCTAssertEqual(
            parse("type=wdata:id=*x*:mime=!!!"),
            .invalid(op: .wdata, id: "x")
        )
    }

    func testPwWithoutNameCleared() {
        let nameless = packet("type=read:pw=c2VjcmV0")
        XCTAssertEqual(nameless.pw, "")
        XCTAssertEqual(nameless.name, "")
        let both = packet("type=read:pw=c2VjcmV0:name=YXBw")
        XCTAssertEqual(both.pw, "secret")
        XCTAssertEqual(both.name, "app")
        let emptyName = packet("type=read:pw=c2VjcmV0:name=")
        XCTAssertEqual(emptyName.pw, "")
        XCTAssertEqual(emptyName.name, "")
    }

    func testOverlongPwIsAbsentNotInvalid() {
        let pw = String(repeating: "p", count: Osc5522.maxPwLen + 1)
        let b64 = Data(pw.utf8).base64EncodedString()
        let p = packet("type=read:pw=\(b64):name=YXBw")
        XCTAssertEqual(p.op, .read)
        XCTAssertEqual(p.pw, "")
        XCTAssertEqual(p.name, "app")
    }

    func testOverlongNameIsInvalid() {
        let name = String(repeating: "n", count: Osc5522.maxNameLen + 1)
        let b64 = Data(name.utf8).base64EncodedString()
        XCTAssertEqual(parse("type=read:name=\(b64)"), .invalid(op: .read, id: ""))
    }

    func testMimeDecodedAndInvalidUtf8() {
        let p = packet("type=wdata:mime=dGV4dC9wbGFpbg==")
        XCTAssertEqual(p.mime, "text/plain")
        XCTAssertEqual(parse("type=wdata:mime=//4="), .invalid(op: .wdata, id: ""))
    }

    func testStrictBase64RejectsWhitespaceMissingPadAndInnerPad() {
        XCTAssertNotNil(Data(base64Encoded: "Z29vZA==\n", options: .ignoreUnknownCharacters))
        XCTAssertNil(Osc5522.strictDecode(Array("Z29vZA==\n".utf8)))
        XCTAssertNil(Osc5522.strictDecode(Array("Z29vZA".utf8)))
        XCTAssertNil(Osc5522.strictDecode(Array("Z29v=A==".utf8)))
        XCTAssertEqual(Osc5522.strictDecode(Array("Z29vZA==".utf8)), Array("good".utf8))

        XCTAssertEqual(parse("type=wdata:mime=dGV4dC9wbGFpbg"), .invalid(op: .wdata, id: ""))
        XCTAssertEqual(parse("type=wdata:mime=dGV4dC9wbGFpbg=!"), .invalid(op: .wdata, id: ""))
        XCTAssertEqual(
            parse("type=wdata:mime=dGV4dC9w\nbGFpbg=="),
            .invalid(op: .wdata, id: "")
        )
    }

    func testStreamingSplitMidGroup() throws {
        var d = Osc5522.StreamingBase64()
        let encoded = Array("c29tZSBkYXRh".utf8)
        let a = try d.feed(Array(encoded[..<3]))
        let b = try d.feed(Array(encoded[3...]))
        try d.finish()
        XCTAssertEqual(String(bytes: a + b, encoding: .utf8), "some data")
    }

    func testStreamingIndependentlyPaddedChunks() throws {
        var d = Osc5522.StreamingBase64()
        let a = try d.feed(Array("Z29vZA==".utf8))
        let b = try d.feed(Array("bW9yZQ==".utf8))
        try d.finish()
        XCTAssertEqual(String(bytes: a + b, encoding: .utf8), "goodmore")
    }

    func testStreamingPadThenDataSamePacket() {
        var d = Osc5522.StreamingBase64()
        XCTAssertThrowsError(try d.feed(Array("Z29vZA==bW9yZQ==".utf8)))
    }

    func testStreamingFinishLeftoverIsInvalid() throws {
        var d = Osc5522.StreamingBase64()
        _ = try d.feed(Array("SGVsbG8".utf8))
        XCTAssertThrowsError(try d.finish())
    }

    func testReplyBytesFieldOrderAndST() {
        XCTAssertEqual(
            Osc5522.Reply(op: .write, status: .DONE).bytes(),
            Array("\u{1B}]5522;type=write:status=DONE\u{1B}\\".utf8)
        )
        XCTAssertEqual(
            Osc5522.Reply(
                op: .read,
                status: .DATA,
                primary: true,
                id: "x",
                mime: "text/plain",
                pw: "otp",
                payload: Array("Ghostty".utf8)
            ).bytes(),
            Array(
                ("\u{1B}]5522;type=read:status=DATA:loc=primary:id=x"
                    + ":mime=dGV4dC9wbGFpbg==:pw=b3Rw;R2hvc3R0eQ==\u{1B}\\").utf8
            )
        )
        XCTAssertEqual(
            Osc5522.Reply(op: .read, status: .DATA, mime: ".").bytes(),
            Array("\u{1B}]5522;type=read:status=DATA:mime=Lg==\u{1B}\\".utf8)
        )
        XCTAssertEqual(
            Osc5522.Reply(op: .write, status: .DONE).bytes().suffix(2),
            [0x1B, 0x5C]
        )
    }

    func testWdataPngPayloadIsNotUtf8Rejected() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let encoded = Array(Data(png).base64EncodedString().utf8)
        let result = Osc5522.ParseResult.parse(
            meta: Array("type=wdata:mime=aW1hZ2UvcG5n".utf8),
            payload: encoded
        )
        guard case .packet(let p) = result else {
            return XCTFail("expected packet, got \(result)")
        }
        XCTAssertEqual(p.op, .wdata)
        XCTAssertEqual(p.mime, "image/png")
        XCTAssertEqual(p.payload, encoded)
        XCTAssertNil(String(bytes: png, encoding: .utf8))
    }

    private final class ReplySink {
        var replies: [Osc5522.Reply] = []
    }

    private func namedPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("jetty.test.osc5522.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private func mimeB64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private func makeWriter(_ pb: NSPasteboard, allow: Bool = true) -> (Osc5522Writer, ReplySink) {
        let sink = ReplySink()
        let w = Osc5522Writer(pasteboard: pb)
        w.writeAllow = allow
        w.onReply = { sink.replies.append($0) }
        return (w, sink)
    }

    private func send(_ w: Osc5522Writer, _ meta: String, payload: String = "") {
        w.handle(meta: Array(meta.utf8), payload: Array(payload.utf8))
    }

    private func writeReply(_ status: Osc5522.Status, id: String = "") -> Osc5522.Reply {
        Osc5522.Reply(op: .write, status: status, id: id)
    }

    func testWriteReplace() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=a")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=write:id=b")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "d29ybGQ=")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.DONE, id: "b")])
        XCTAssertEqual(pb.string(forType: .string), "world")
        XCTAssertEqual(w.phase, .idle)
    }

    func testCommitWithoutBeginIsSilent() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=wdata")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=walias:mime=\(mimeB64("text/plain"))", payload: "VEVYVA==")
        XCTAssertTrue(sink.replies.isEmpty)
        XCTAssertEqual(w.phase, .idle)
        XCTAssertNil(pb.string(forType: .string))
    }

    func testWriteAlias() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "R2hvc3R0eQ==")
        send(w, "type=walias:mime=\(mimeB64("text/plain"))", payload: "VEVYVCBVVEY4X1NUUklORw==")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.DONE, id: "w1")])
        XCTAssertEqual(pb.string(forType: .string), "Ghostty")
        XCTAssertEqual(
            pb.data(forType: Osc5522Pasteboard.pasteboardType(forMime: "TEXT")),
            Data("Ghostty".utf8)
        )
        XCTAssertEqual(
            pb.data(forType: Osc5522Pasteboard.pasteboardType(forMime: "UTF8_STRING")),
            Data("Ghostty".utf8)
        )
    }

    func testWriteAliasDroppedWhenTargetHasNoData() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=walias:mime=\(mimeB64("text/plain"))", payload: "VEVYVA==")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.DONE, id: "w1")])
        XCTAssertNil(pb.data(forType: .init("TEXT")))
    }

    func testWriteMimeOverwrite() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "YQ==")
        send(w, "type=wdata:mime=\(mimeB64("text/html"))", payload: "Yg==")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "Yw==")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.DONE, id: "w1")])
        XCTAssertEqual(pb.string(forType: .string), "c")
        XCTAssertEqual(pb.data(forType: .html), Data("b".utf8))
    }

    func testWriteOver64MiBIsEFBIG() {
        XCTAssertEqual(Osc5522.maxWriteBytes, 64 * 1024 * 1024)
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=big")
        guard let st = w.state else { return XCTFail("expected accumulating") }
        st.spool = [UInt8](repeating: 0, count: Osc5522.maxWriteBytes)
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "YQ==")
        XCTAssertEqual(sink.replies, [writeReply(.EFBIG, id: "big")])
        XCTAssertEqual(w.phase, .ignoringWrites)
    }

    func testPrimaryWriteIsENOSYS() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:loc=primary:id=p1")
        XCTAssertEqual(sink.replies, [writeReply(.ENOSYS, id: "p1")])
        XCTAssertEqual(w.phase, .ignoringWrites)
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.ENOSYS, id: "p1")])
        XCTAssertNil(pb.string(forType: .string))
    }

    func testWriteDenyIsEPERM() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb, allow: false)
        send(w, "type=write:id=z")
        XCTAssertEqual(sink.replies, [writeReply(.EPERM, id: "z")])
        XCTAssertEqual(w.phase, .ignoringWrites)
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies.count, 1)
    }

    func testWriteDenyAtCommitIsEPERM() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=z")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        w.writeAllow = false
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.EPERM, id: "z")])
        XCTAssertNil(pb.string(forType: .string))
    }

    func testEmptyWaliasMimeWithLiveWriteIsEINVAL() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=walias")
        XCTAssertEqual(sink.replies, [writeReply(.EINVAL, id: "w1")])
        XCTAssertEqual(w.phase, .ignoringWrites)
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies.count, 1)
    }

    func testInvalidWdataMimeWithLiveWriteIsEINVAL() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=!!!")
        XCTAssertEqual(sink.replies, [writeReply(.EINVAL, id: "w1")])
        XCTAssertEqual(w.phase, .ignoringWrites)
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies.count, 1)
    }

    func testInvalidWdataPayloadWithLiveWriteIsEINVAL() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "!!!")
        XCTAssertEqual(sink.replies, [writeReply(.EINVAL, id: "w1")])
    }

    func testInvalidReadDoesNotAbortLiveWrite() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=read:mime=!!!")
        send(w, "type=bobr")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.DONE, id: "w1")])
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    func testUnpaddedWdataCommitIsEINVAL() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "SGVsbG8")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [writeReply(.EINVAL, id: "w1")])
    }

    func testInvalidUtf8AliasListIsEINVAL() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=walias:mime=\(mimeB64("text/plain"))", payload: "/w==")
        XCTAssertEqual(sink.replies, [writeReply(.EINVAL, id: "w1")])
    }

    func testWriteFromIgnoringWritesRestarts() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:loc=primary:id=p1")
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=wdata")
        XCTAssertEqual(sink.replies, [
            writeReply(.ENOSYS, id: "p1"),
            writeReply(.DONE, id: "w1"),
        ])
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    func testReplyDoneWithIdUsesST() {
        let pb = namedPasteboard()
        let (w, sink) = makeWriter(pb)
        send(w, "type=write:id=w1")
        send(w, "type=wdata:mime=\(mimeB64("text/plain"))", payload: "aGVsbG8=")
        send(w, "type=wdata")
        XCTAssertEqual(
            sink.replies.last?.bytes(),
            Osc5522.Reply(op: .write, status: .DONE, id: "w1").bytes()
        )
        XCTAssertEqual(sink.replies.last?.bytes().suffix(2), [0x1B, 0x5C])
        XCTAssertEqual(
            String(bytes: sink.replies.last?.bytes() ?? [], encoding: .utf8),
            "\u{1B}]5522;type=write:status=DONE:id=w1\u{1B}\\"
        )
    }

    func testAvailableDeclaredTypesOnly() {
        let pb = namedPasteboard()
        pb.declareTypes([.tiff], owner: nil)
        XCTAssertNil(pb.data(forType: .tiff))
        let mimes = Osc5522Pasteboard.available(pb)
        XCTAssertTrue(mimes.contains("image/tiff"))
        XCTAssertTrue(mimes.contains("image/png"))
        XCTAssertNil(pb.data(forType: .tiff))
    }

    func testAvailableFileURLInfersUriListAndPlain() {
        let pb = namedPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/osc5522-a") as NSURL])
        let mimes = Osc5522Pasteboard.available(pb)
        XCTAssertTrue(mimes.contains("text/uri-list"))
        XCTAssertTrue(mimes.contains("text/plain"))
    }

    func testAvailableCharsetStripped() {
        XCTAssertEqual(Osc5522Pasteboard.normalizeMime("text/plain;charset=utf-8"), "text/plain")
        let pb = namedPasteboard()
        pb.declareTypes([.init("text/plain;charset=utf-8")], owner: nil)
        XCTAssertEqual(Osc5522Pasteboard.available(pb), ["text/plain"])
    }

    func testWriteNoFilesIsOneItem() {
        let pb = namedPasteboard()
        XCTAssertTrue(Osc5522Pasteboard.write(pb, contents: [
            ("text/plain", Data("hello".utf8)),
        ]))
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    func testWriteTwoFileURLsAreTwoItemsAndStringOnce() {
        let pb = namedPasteboard()
        let body = "file:///tmp/osc5522-a\r\nfile:///tmp/osc5522-b\r\n"
        XCTAssertTrue(Osc5522Pasteboard.write(pb, contents: [
            ("text/plain", Data("hello".utf8)),
            ("text/uri-list", Data(body.utf8)),
        ]))
        let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(urls?.count, 2)
        XCTAssertEqual(pb.string(forType: .string), "hello")
        let items = pb.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[1].string(forType: .string))
        XCTAssertNotNil(items[1].string(forType: .fileURL))
    }

    func testOsc5522HopDoesNotTakeSessionLock() {
        let session = TerminalSession(
            cols: 10, rows: 2, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0
        )
        session.lock.lock()
        session.parser.feed("\u{1B}]5522;type=write:id=hop\u{07}")
        session.lock.unlock()
    }

    func testOsc5522HopWriteDone() {
        let session = TerminalSession(
            cols: 10, rows: 2, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0
        )
        let pb = namedPasteboard()
        session.osc5522Writer.pasteboard = pb
        let exp = expectation(description: "done")
        session.osc5522ReplySink = { bytes in
            if bytes == Osc5522.Reply(op: .write, status: .DONE, id: "w1").bytes() {
                exp.fulfill()
            }
        }
        session.parser.feed(
            "\u{1B}]5522;type=write:id=w1\u{1B}\\"
                + "\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGVsbG8=\u{1B}\\"
                + "\u{1B}]5522;type=wdata\u{1B}\\"
        )
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    func testStopWithoutPtyDoesNotHang() {
        let session = TerminalSession(
            cols: 10, rows: 2, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0
        )
        session.writeToPty(Array("x".utf8))
        session.stop()
        session.writeToPty(Array("y".utf8))
    }

    private final class PacketBox: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [[UInt8]] = []
        func add(_ p: [UInt8]) {
            lock.lock()
            packets.append(p)
            lock.unlock()
        }
        func all() -> [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return packets
        }
    }

    private func makeSession(_ pb: NSPasteboard) -> TerminalSession {
        let session = TerminalSession(
            cols: 10, rows: 2, cellWidthPx: 8, cellHeightPx: 16, scrollbackCapRows: 0
        )
        session.osc5522Writer.pasteboard = pb
        session.storedPasswords = Osc5522StoredPasswords()
        return session
    }

    private func runOnMain(_ body: @escaping @MainActor () -> Void) {
        let exp = expectation(description: "main")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body()
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    private func attach(_ session: TerminalSession) -> PacketBox {
        let box = PacketBox()
        session.osc5522ReplySink = { box.add($0) }
        return box
    }

    private func sendRead(_ session: TerminalSession, _ meta: String, payload: String) {
        runOnMain {
            session.handleOsc5522(
                meta: Array(meta.utf8), payload: Array(payload.utf8), quantum: 4096
            )
        }
    }

    private func readReply(
        _ status: Osc5522.Status,
        id: String = "",
        mime: String? = nil,
        payload: [UInt8] = []
    ) -> [UInt8] {
        Osc5522.Reply(op: .read, status: status, id: id, mime: mime, payload: payload).bytes()
    }

    private func mimeListPayload(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private func fieldB64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    private func waitContains(
        _ box: PacketBox,
        _ packet: [UInt8],
        timeout: TimeInterval = 2
    ) {
        let exp = expectation(description: "packet")
        exp.assertForOverFulfill = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if box.all().contains(packet) {
                exp.fulfill()
                wait(for: [exp], timeout: 0.1)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("missing packet, got \(box.all().count)")
    }

    func testReadListingNoPrompt() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        var prompted = false
        session.onOsc5522Prompt = { _, reply in
            prompted = true
            reply(.deny)
        }
        let box = attach(session)
        sendRead(session, "type=read:id=l1", payload: mimeListPayload("."))
        XCTAssertFalse(prompted)
        let listing = Osc5522.listingPayload(Osc5522Pasteboard.available(pb))
        XCTAssertEqual(box.all().first, readReply(.OK, id: "l1"))
        XCTAssertTrue(
            box.all().contains(
                readReply(.DATA, id: "l1", mime: ".", payload: listing)
            )
        )
        XCTAssertEqual(box.all().last, readReply(.DONE, id: "l1"))
    }

    func testEmptyListingSendsDATAWithoutPayload() {
        let pb = namedPasteboard()
        let session = makeSession(pb)
        var prompted = false
        session.onOsc5522Prompt = { _, _ in prompted = true }
        let box = attach(session)
        sendRead(session, "type=read", payload: mimeListPayload("."))
        XCTAssertFalse(prompted)
        XCTAssertTrue(box.all().contains(readReply(.DATA, mime: ".")))
        XCTAssertEqual(box.all().last, readReply(.DONE))
    }

    func testReadDataPromptAllow() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        var prompted = 0
        session.onOsc5522Prompt = { prompt, reply in
            prompted += 1
            XCTAssertEqual(prompt.direction, .read)
            XCTAssertEqual(prompt.name, "app")
            XCTAssertTrue(prompt.offersAlways)
            reply(.allow)
        }
        let box = attach(session)
        sendRead(
            session,
            "type=read:id=r1:pw=\(fieldB64("secret")):name=\(fieldB64("app"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertEqual(prompted, 1)
        waitContains(box, readReply(.DONE, id: "r1"))
        XCTAssertTrue(box.all().contains(readReply(.OK, id: "r1")))
        XCTAssertTrue(
            box.all().contains(
                readReply(.DATA, id: "r1", mime: "text/plain", payload: Array("hello".utf8))
            )
        )
    }

    func testReadDenyConfigEPERM() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        session.osc52ReadAsk = false
        var prompted = false
        session.onOsc5522Prompt = { _, _ in prompted = true }
        let box = attach(session)
        sendRead(session, "type=read:id=d1", payload: mimeListPayload("text/plain"))
        XCTAssertFalse(prompted)
        XCTAssertEqual(box.all(), [readReply(.EPERM, id: "d1")])
    }

    func testOTPDoesNotBypassDeny() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        session.osc52ReadAsk = false
        let otp = session.installPasteOTP()
        let box = attach(session)
        sendRead(
            session,
            "type=read:id=d2:pw=\(fieldB64(otp)):name=\(fieldB64("app"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertEqual(box.all(), [readReply(.EPERM, id: "d2")])
        XCTAssertEqual(session.osc5522Grants.entries.filter(\.oneTime).count, 1)
    }

    func testOnOsc5522PromptNilIsEPERM() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        let box = attach(session)
        sendRead(session, "type=read:id=n1", payload: mimeListPayload("text/plain"))
        XCTAssertEqual(box.all(), [readReply(.EPERM, id: "n1")])
    }

    func testSecondUnauthenticatedReadDuringPromptIsEBUSY() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        var pending: ((Osc5522Decision) -> Void)?
        session.onOsc5522Prompt = { _, reply in pending = reply }
        let box = attach(session)
        sendRead(session, "type=read:id=a", payload: mimeListPayload("text/plain"))
        sendRead(session, "type=read:id=b", payload: mimeListPayload("text/plain"))
        XCTAssertEqual(box.all(), [readReply(.EBUSY, id: "b")])
        runOnMain { pending?(.deny) }
        XCTAssertTrue(box.all().contains(readReply(.EPERM, id: "a")))
    }

    func testOTPDuringDataReplyInFlightIsEBUSY() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        let otp = session.installPasteOTP()
        let box = attach(session)
        let meta = "type=read:id=busy:pw=\(fieldB64(otp)):name=\(fieldB64("app"))"
        let payload = mimeListPayload("text/plain")
        runOnMain {
            session.dataReplyGen = 1
            session.dataReplyInFlight = true
            session.handleOsc5522(
                meta: Array(meta.utf8),
                payload: Array(payload.utf8),
                quantum: 4096
            )
        }
        XCTAssertEqual(box.all(), [readReply(.EBUSY, id: "busy")])
        XCTAssertEqual(session.osc5522Grants.entries.filter(\.oneTime).count, 1)
    }

    func testOTPDuringOpenSheetIdleIOAllows() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        var pending: ((Osc5522Decision) -> Void)?
        session.onOsc5522Prompt = { _, reply in pending = reply }
        let box = attach(session)
        sendRead(session, "type=read:id=sheet", payload: mimeListPayload("text/plain"))
        XCTAssertNotNil(pending)
        XCTAssertTrue(session.osc5522PromptOpen)
        let otp = session.installPasteOTP()
        sendRead(
            session,
            "type=read:id=otp:pw=\(fieldB64(otp)):name=\(fieldB64("app"))",
            payload: mimeListPayload("text/plain")
        )
        waitContains(box, readReply(.DONE, id: "otp"))
        XCTAssertTrue(session.osc5522PromptOpen)
        XCTAssertTrue(session.osc5522Grants.entries.filter(\.oneTime).isEmpty)
        runOnMain { pending?(.deny) }
        XCTAssertTrue(box.all().contains(readReply(.EPERM, id: "sheet")))
    }

    func testListingNotWrittenWhileDataInFlight() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        let box = attach(session)
        session.dataReplyGen = 1
        session.dataReplyInFlight = true
        XCTAssertFalse(session.sendPasteEvent(from: pb, snapshot: false))
        XCTAssertTrue(box.all().isEmpty)
    }

    func testStaleGenClearKeepsInFlight() {
        let session = makeSession(namedPasteboard())
        runOnMain {
            session.dataReplyGen = 2
            session.dataReplyInFlight = true
            session.clearDataReplyIfCurrent(gen: 1)
            XCTAssertTrue(session.dataReplyInFlight)
            session.clearDataReplyIfCurrent(gen: 2)
            XCTAssertFalse(session.dataReplyInFlight)
        }
    }

    func testSheetAllowAfterOTPStartedDATAIsEBUSY() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        var pending: ((Osc5522Decision) -> Void)?
        session.onOsc5522Prompt = { _, reply in pending = reply }
        let box = attach(session)
        let payload = mimeListPayload("text/plain")
        runOnMain {
            session.handleOsc5522(
                meta: Array("type=read:id=sheet".utf8),
                payload: Array(payload.utf8),
                quantum: 4096
            )
            let otp = session.installPasteOTP()
            let otpMeta = "type=read:id=otp:pw=\(Data(otp.utf8).base64EncodedString()):name=\(Data("app".utf8).base64EncodedString())"
            session.handleOsc5522(
                meta: Array(otpMeta.utf8),
                payload: Array(payload.utf8),
                quantum: 4096
            )
            pending?(.allow)
        }
        waitContains(box, readReply(.EBUSY, id: "sheet"))
        waitContains(box, readReply(.DONE, id: "otp"))
    }

    func testOTPConsumeTimeoutAndNamelessIgnored() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        let box = attach(session)
        let otp = session.installPasteOTP()
        sendRead(
            session,
            "type=read:pw=\(fieldB64(otp))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertEqual(box.all(), [readReply(.EPERM)])
        XCTAssertEqual(session.osc5522Grants.entries.filter(\.oneTime).count, 1)

        sendRead(
            session,
            "type=read:id=once:pw=\(fieldB64(otp)):name=\(fieldB64("app"))",
            payload: mimeListPayload("text/plain")
        )
        waitContains(box, readReply(.DONE, id: "once"))
        XCTAssertTrue(session.osc5522Grants.entries.filter(\.oneTime).isEmpty)

        sendRead(
            session,
            "type=read:id=again:pw=\(fieldB64(otp)):name=\(fieldB64("app"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertTrue(box.all().contains(readReply(.EPERM, id: "again")))

        session.installPasteOTP(deadline: Date.distantPast)
        let expired = session.osc5522Grants.entries.first { $0.oneTime }?.pw ?? ""
        sendRead(
            session,
            "type=read:id=exp:pw=\(fieldB64(expired)):name=\(fieldB64("app"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertTrue(box.all().contains(readReply(.EPERM, id: "exp")))
        XCTAssertTrue(session.osc5522Grants.entries.filter(\.oneTime).isEmpty)
    }

    func testPrimaryReadIsENOSYS() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        var prompted = false
        session.onOsc5522Prompt = { _, _ in prompted = true }
        let box = attach(session)
        sendRead(session, "type=read:loc=primary:id=p1", payload: mimeListPayload("."))
        XCTAssertFalse(prompted)
        XCTAssertEqual(box.all(), [readReply(.ENOSYS, id: "p1")])
    }

    func testInvalidReadPayloadIsDropped() {
        let pb = namedPasteboard()
        let session = makeSession(pb)
        let box = attach(session)
        sendRead(session, "type=read:id=bad", payload: "!!!")
        sendRead(session, "type=read:id=bad2", payload: "/w==")
        XCTAssertTrue(box.all().isEmpty)
    }

    func testStoredFileParseLastNameWinsAndMatch() {
        let stored = Osc5522StoredPasswords.parse("""
            # comment
            name = neovim
            password = first

            name = drop

            name = neovim
            password = 550e8400-e29b-41d4-a716-446655440000

            name = yazi
            password = 7c9e6679-7425-40de-944b-e07fc1f90ae7
            """)
        XCTAssertEqual(stored.records.map(\.name), ["neovim", "yazi"])
        XCTAssertEqual(stored.records[0].password, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertTrue(
            stored.match(name: "neovim", password: "550e8400-e29b-41d4-a716-446655440000")
        )
        XCTAssertFalse(stored.match(name: "neovim", password: "first"))
        XCTAssertFalse(stored.match(name: "other", password: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertFalse(stored.match(name: "neovim", password: "wrong"))
        XCTAssertFalse(stored.match(name: "", password: "550e8400-e29b-41d4-a716-446655440000"))
    }

    func testStoredMatchNeedsNameAndPwOnRead() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        session.storedPasswords = Osc5522StoredPasswords.parse("""
            name = neovim
            password = secret-pw
            """)
        var prompted = false
        session.onOsc5522Prompt = { _, reply in
            prompted = true
            reply(.deny)
        }
        let box = attach(session)
        sendRead(
            session,
            "type=read:id=s1:pw=\(fieldB64("secret-pw")):name=\(fieldB64("neovim"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertFalse(prompted)
        waitContains(box, readReply(.DONE, id: "s1"))

        sendRead(
            session,
            "type=read:id=s2:pw=\(fieldB64("secret-pw")):name=\(fieldB64("other"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertTrue(prompted)
        XCTAssertTrue(box.all().contains(readReply(.EPERM, id: "s2")))
    }

    func testDenyBeatsStored() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        session.osc52ReadAsk = false
        session.storedPasswords = Osc5522StoredPasswords.parse("""
            name = neovim
            password = secret-pw
            """)
        let box = attach(session)
        sendRead(
            session,
            "type=read:id=s3:pw=\(fieldB64("secret-pw")):name=\(fieldB64("neovim"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertEqual(box.all(), [readReply(.EPERM, id: "s3")])
    }

    func testBanBeatsStored() {
        let pb = namedPasteboard()
        pb.setString("hello", forType: .string)
        let session = makeSession(pb)
        session.storedPasswords = Osc5522StoredPasswords.parse("""
            name = neovim
            password = secret-pw
            """)
        session.osc5522Grants.ban("secret-pw", .read)
        var prompted = false
        session.onOsc5522Prompt = { _, _ in prompted = true }
        let box = attach(session)
        sendRead(
            session,
            "type=read:id=s4:pw=\(fieldB64("secret-pw")):name=\(fieldB64("neovim"))",
            payload: mimeListPayload("text/plain")
        )
        XCTAssertFalse(prompted)
        XCTAssertEqual(box.all(), [readReply(.EPERM, id: "s4")])
    }

    func testEnsureClipboardPasswordsFileIs0600() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetty-pw-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("clipboard-passwords")
        defer { try? FileManager.default.removeItem(at: dir) }
        let got = AppConfig.ensureClipboardPasswordsFile(at: url)
        XCTAssertEqual(got, url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((perms?.uint16Value ?? 0) & 0o777, 0o600)
        let parsed = Osc5522StoredPasswords.load(from: url)
        XCTAssertTrue(parsed.records.isEmpty)
    }

    func testDataUsesPasteboardTypeNotRawMime() {
        let pb = namedPasteboard()
        XCTAssertTrue(Osc5522Pasteboard.write(pb, contents: [
            ("application/x-foo", Data("x".utf8)),
        ]))
        XCTAssertEqual(Osc5522Pasteboard.data(pb, mime: "application/x-foo"), Data("x".utf8))
        XCTAssertNil(pb.data(forType: .init("application/x-foo")))
        XCTAssertEqual(
            pb.data(forType: Osc5522Pasteboard.pasteboardType(forMime: "application/x-foo")),
            Data("x".utf8)
        )
    }

    func testDataFileOnlyPlainTextIsUnquotedPaths() {
        let pb = namedPasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/osc5522 path") as NSURL])
        XCTAssertEqual(
            Osc5522Pasteboard.data(pb, mime: "text/plain"),
            Data("/tmp/osc5522 path".utf8)
        )
        let uri = Osc5522Pasteboard.data(pb, mime: "text/uri-list")
        XCTAssertEqual(uri, Data("file:///tmp/osc5522%20path\r\n".utf8))
    }

    func testReadChunkAt4096() {
        let pb = namedPasteboard()
        let text = String(repeating: "a", count: Osc5522.readChunk + 1)
        pb.setString(text, forType: .string)
        let session = makeSession(pb)
        session.onOsc5522Prompt = { _, reply in reply(.allow) }
        let box = attach(session)
        sendRead(session, "type=read:id=big", payload: mimeListPayload("text/plain"))
        waitContains(box, readReply(.DONE, id: "big"))
        let first = Array(repeating: UInt8(ascii: "a"), count: Osc5522.readChunk)
        let second: [UInt8] = [UInt8(ascii: "a")]
        XCTAssertTrue(
            box.all().contains(readReply(.DATA, id: "big", mime: "text/plain", payload: first))
        )
        XCTAssertTrue(
            box.all().contains(readReply(.DATA, id: "big", mime: "text/plain", payload: second))
        )
    }

    func testSanitizeNameStripsControlsAndBidi() {
        XCTAssertEqual(Osc5522.sanitizeName("ok"), "ok")
        XCTAssertEqual(Osc5522.sanitizeName("a\u{0001}b\u{202E}c"), "abc")
        XCTAssertTrue(Osc5522.timingSafeEqual("pw", "pw"))
        XCTAssertFalse(Osc5522.timingSafeEqual("pw", "pq"))
        let otp = Osc5522.randomOTP()
        XCTAssertEqual(otp.count, Osc5522.otpLength)
        XCTAssertTrue(otp.utf8.allSatisfy { Osc5522.otpAlphabet.contains($0) })
    }
}
