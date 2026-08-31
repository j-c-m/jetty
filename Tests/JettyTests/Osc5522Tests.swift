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
}
