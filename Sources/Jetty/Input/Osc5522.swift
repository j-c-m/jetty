import AppKit
import Foundation
import Security

public enum Osc5522 {
    public static let maxWriteBytes = 64 * 1024 * 1024
    public static let maxQueuedBytes = 2 * maxWriteBytes
    public static let maxReadBytes = 8 * 1024 * 1024
    public static let queueQuantum = 4096
    public static let readChunk = 4096
    public static let maxIdLen = 512
    public static let maxPwLen = 128
    public static let maxMimeLen = 256
    public static let maxNameLen = 256
    public static let maxWriteMimes = 64
    public static let maxWriteAliases = 64
    public static let maxReadMimes = 8
    public static let maxListingMimes = 16
    public static let otpTimeout: TimeInterval = 5
    public static let targetsMime = "."
    public static let pasteEventName = "Paste event"

    public enum Op: String, Equatable {
        case read, write, wdata, walias
    }

    public enum Status: String, Equatable {
        case OK, DATA, DONE, ENOSYS, EPERM, EBUSY, EIO, EINVAL, EFBIG
    }

    public struct Packet: Equatable {
        public var op: Op
        public var primary: Bool
        public var id: String
        public var mime: String
        public var pw: String
        public var name: String
        public var payload: [UInt8]
    }

    public enum ParseResult: Equatable {
        case drop
        case invalid(op: Op?, id: String)
        case packet(Packet)

        /// Split metadata on `:`. Every record needs `=`. Unknown `type` drops.
        public static func parse(meta: [UInt8], payload: [UInt8]) -> ParseResult {
            var opRaw: [UInt8]?
            var loc: [UInt8] = []
            var idRaw: [UInt8] = []
            var mimeB64: [UInt8] = []
            var pwB64: [UInt8] = []
            var nameB64: [UInt8] = []

            var start = 0
            var i = 0
            while i <= meta.count {
                if i == meta.count || meta[i] == UInt8(ascii: ":") {
                    let rec = meta[start..<i]
                    guard let eq = rec.firstIndex(of: UInt8(ascii: "=")) else { return .drop }
                    let key = rec[rec.startIndex..<eq]
                    let value = rec[rec.index(after: eq)..<rec.endIndex]
                    if key.elementsEqual("type".utf8) {
                        opRaw = Array(value)
                    } else if key.elementsEqual("loc".utf8) {
                        loc = Array(value)
                    } else if key.elementsEqual("id".utf8) {
                        idRaw = Array(value)
                    } else if key.elementsEqual("mime".utf8) {
                        mimeB64 = Array(value)
                    } else if key.elementsEqual("pw".utf8) {
                        pwB64 = Array(value)
                    } else if key.elementsEqual("name".utf8) {
                        nameB64 = Array(value)
                    }
                    start = i + 1
                }
                i += 1
            }

            let op = opRaw.flatMap(Osc5522.op(from:))
            let id = sanitizeId(idRaw)
            guard let op else { return .drop }

            let mime: String
            switch decodeField(mimeB64, maxLen: maxMimeLen, overflowAsAbsent: false) {
            case .ok(let s): mime = s
            case .invalid: return .invalid(op: op, id: id)
            }
            let name: String
            switch decodeField(nameB64, maxLen: maxNameLen, overflowAsAbsent: false) {
            case .ok(let s): name = s
            case .invalid: return .invalid(op: op, id: id)
            }
            let pwDecoded: String
            switch decodeField(pwB64, maxLen: maxPwLen, overflowAsAbsent: true) {
            case .ok(let s): pwDecoded = s
            case .invalid: return .invalid(op: op, id: id)
            }

            var pw = pwDecoded
            var nameOut = name
            if nameOut.isEmpty {
                pw = ""
                nameOut = ""
            }

            return .packet(Packet(
                op: op,
                primary: loc.elementsEqual("primary".utf8),
                id: id,
                mime: mime,
                pw: pw,
                name: nameOut,
                payload: payload
            ))
        }
    }

    public struct Reply: Equatable {
        public var op: Op
        public var status: Status
        public var primary: Bool = false
        public var id: String = ""
        public var mime: String? = nil
        public var pw: String? = nil
        public var payload: [UInt8] = []

        public init(
            op: Op,
            status: Status,
            primary: Bool = false,
            id: String = "",
            mime: String? = nil,
            pw: String? = nil,
            payload: [UInt8] = []
        ) {
            self.op = op
            self.status = status
            self.primary = primary
            self.id = id
            self.mime = mime
            self.pw = pw
            self.payload = payload
        }

        public func bytes() -> [UInt8] {
            var s = "\u{1B}]5522;type=\(op.rawValue):status=\(status.rawValue)"
            if primary { s += ":loc=primary" }
            if !id.isEmpty { s += ":id=\(id)" }
            if let mime {
                s += ":mime=\(Data(mime.utf8).base64EncodedString())"
            }
            if let pw {
                s += ":pw=\(Data(pw.utf8).base64EncodedString())"
            }
            if !payload.isEmpty {
                s += ";\(Data(payload).base64EncodedString())"
            }
            s += "\u{1B}\\"
            return Array(s.utf8)
        }
    }

    /// Strict RFC 4648. A packet that ends on complete padding restarts the stream.
    public struct StreamingBase64 {
        public enum Error: Swift.Error { case invalid }

        private var pending: [UInt8] = []
        private var padsInGroup = 0
        private var endedOnPad = false

        public init() {}

        public mutating func feed(_ input: [UInt8]) throws -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(input.count / 4 * 3 + 3)
            for b in input {
                if endedOnPad { throw Error.invalid }
                try consume(b, into: &out)
            }
            if endedOnPad {
                endedOnPad = false
                padsInGroup = 0
                pending.removeAll(keepingCapacity: true)
            }
            return out
        }

        public mutating func finish() throws {
            if !pending.isEmpty { throw Error.invalid }
            endedOnPad = false
            padsInGroup = 0
        }
    }

    public static func strictDecode(_ input: [UInt8]) -> [UInt8]? {
        var d = StreamingBase64()
        guard let out = try? d.feed(input) else { return nil }
        guard (try? d.finish()) != nil else { return nil }
        return out
    }

    public struct ReadList: Equatable {
        public var wantListing: Bool
        public var mimes: [String]
    }

    /// Invalid base64 / UTF-8 → nil (silent drop). `.` is listing, not a data type.
    public static func parseReadList(_ payload: [UInt8]) -> ReadList? {
        if payload.isEmpty { return ReadList(wantListing: false, mimes: []) }
        guard let decoded = strictDecode(payload) else { return nil }
        guard let text = String(bytes: decoded, encoding: .utf8) else { return nil }
        var wantListing = false
        var mimes: [String] = []
        var seen = Set<String>()
        for part in text.split(whereSeparator: \.isWhitespace) {
            let raw = String(part)
            if raw == targetsMime {
                wantListing = true
                continue
            }
            let mime = Osc5522Pasteboard.normalizeMime(raw)
            guard !mime.isEmpty, seen.insert(mime).inserted else { continue }
            if mimes.count >= maxReadMimes { continue }
            mimes.append(mime)
        }
        return ReadList(wantListing: wantListing, mimes: mimes)
    }

    public static func listingPayload(_ mimes: [String]) -> [UInt8] {
        if mimes.isEmpty { return [] }
        return Array((mimes.joined(separator: " ") + "\n").utf8)
    }

    public static func sanitizeName(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for sc in s.unicodeScalars {
            let v = sc.value
            if v < 0x20 { continue }
            if v >= 0x7F && v < 0xA0 { continue }
            if v >= 0x202A && v <= 0x2069 { continue }
            out.unicodeScalars.append(sc)
        }
        if out.utf8.count <= maxNameLen { return out }
        var bytes = Array(out.utf8.prefix(maxNameLen))
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    public static func timingSafeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        let n = max(ab.count, bb.count)
        var diff: UInt8 = ab.count == bb.count ? 0 : 1
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= x ^ y
            i += 1
        }
        return diff == 0
    }

    public static let otpAlphabet = Array(
        "23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ".utf8
    )
    public static let otpLength = 22

    public static func randomOTP() -> String {
        var raw = [UInt8](repeating: 0, count: otpLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        if status != errSecSuccess {
            for i in raw.indices { raw[i] = UInt8.random(in: 0...255) }
        }
        let alpha = otpAlphabet
        var out = [UInt8](repeating: 0, count: otpLength)
        for i in raw.indices {
            out[i] = alpha[Int(raw[i]) % alpha.count]
        }
        return String(bytes: out, encoding: .ascii) ?? ""
    }
}

extension Osc5522 {
    private enum Field {
        case ok(String)
        case invalid
    }

    private static func op(from raw: [UInt8]) -> Op? {
        Op(rawValue: String(bytes: raw, encoding: .ascii) ?? "")
    }

    private static func sanitizeId(_ raw: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(min(raw.count, maxIdLen))
        for b in raw {
            let ok =
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || b == UInt8(ascii: "-")
                || b == UInt8(ascii: "_")
                || b == UInt8(ascii: "+")
                || b == UInt8(ascii: ".")
            guard ok else { continue }
            out.append(b)
            if out.count == maxIdLen { break }
        }
        return String(bytes: out, encoding: .ascii) ?? ""
    }

    private static func decodeField(
        _ b64: [UInt8],
        maxLen: Int,
        overflowAsAbsent: Bool
    ) -> Field {
        if b64.isEmpty { return .ok("") }
        let maxEnc = 4 * ((maxLen + 2) / 3)
        if b64.count > maxEnc {
            return overflowAsAbsent ? .ok("") : .invalid
        }
        guard let decoded = strictDecode(b64) else { return .invalid }
        if decoded.count > maxLen {
            return overflowAsAbsent ? .ok("") : .invalid
        }
        guard let s = String(bytes: decoded, encoding: .utf8) else { return .invalid }
        return .ok(s)
    }
}

extension Osc5522.StreamingBase64 {
    private static let table: [UInt8] = {
        var t = [UInt8](repeating: 0xFF, count: 256)
        let alpha = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (i, c) in alpha.enumerated() { t[Int(c)] = UInt8(i) }
        return t
    }()

    private mutating func consume(_ b: UInt8, into out: inout [UInt8]) throws {
        if b == UInt8(ascii: "=") {
            if padsInGroup == 0 {
                if pending.count < 2 { throw Error.invalid }
            } else if padsInGroup == 1 {
                if pending.count != 3 { throw Error.invalid }
            } else {
                throw Error.invalid
            }
            pending.append(b)
            padsInGroup += 1
            if pending.count == 4 {
                try flush(into: &out)
                endedOnPad = true
            }
            return
        }
        if padsInGroup != 0 { throw Error.invalid }
        guard Self.table[Int(b)] < 64 else { throw Error.invalid }
        pending.append(b)
        if pending.count == 4 {
            try flush(into: &out)
        }
    }

    private mutating func flush(into out: inout [UInt8]) throws {
        out.append(contentsOf: try Self.decodeQuantum(pending))
        pending.removeAll(keepingCapacity: true)
        padsInGroup = 0
    }

    private static func decodeQuantum(_ q: [UInt8]) throws -> [UInt8] {
        let v0 = Int(table[Int(q[0])])
        let v1 = Int(table[Int(q[1])])
        if v0 > 63 || v1 > 63 { throw Error.invalid }
        let pad2 = q[2] == UInt8(ascii: "=")
        let pad3 = q[3] == UInt8(ascii: "=")
        if pad2 && !pad3 { throw Error.invalid }
        if pad2 {
            if (v1 & 0x0F) != 0 { throw Error.invalid }
            return [UInt8((v0 << 2) | (v1 >> 4))]
        }
        let v2 = Int(table[Int(q[2])])
        if v2 > 63 { throw Error.invalid }
        if pad3 {
            if (v2 & 0x03) != 0 { throw Error.invalid }
            return [
                UInt8((v0 << 2) | (v1 >> 4)),
                UInt8(((v1 & 0x0F) << 4) | (v2 >> 2)),
            ]
        }
        let v3 = Int(table[Int(q[3])])
        if v3 > 63 { throw Error.invalid }
        return [
            UInt8((v0 << 2) | (v1 >> 4)),
            UInt8(((v1 & 0x0F) << 4) | (v2 >> 2)),
            UInt8(((v2 & 0x03) << 6) | v3),
        ]
    }
}

final class Osc5522WriteState {
    enum Error: Swift.Error { case invalid, tooLarge }

    let id: String
    let primary: Bool
    let pw: String
    let name: String
    var spool: [UInt8] = []
    var entries: [(mime: String, start: Int, len: Int)] = []
    var aliases: [(alias: String, target: String)] = []
    var current: Int?
    var decoder = Osc5522.StreamingBase64()
    let maxSize: Int

    init(id: String, primary: Bool, pw: String, name: String, maxSize: Int) {
        self.id = id
        self.primary = primary
        self.pw = pw
        self.name = name
        self.maxSize = maxSize
    }

    func data(mime: String, payload: [UInt8]) throws {
        if let idx = current {
            if entries[idx].mime == mime {
                try append(payload)
                return
            }
            try finishCurrent()
        }
        if let idx = entries.firstIndex(where: { $0.mime == mime }) {
            entries[idx].start = spool.count
            entries[idx].len = 0
            current = idx
            try append(payload)
            return
        }
        if entries.count >= Osc5522.maxWriteMimes {
            current = nil
            return
        }
        entries.append((mime: mime, start: spool.count, len: 0))
        current = entries.count - 1
        try append(payload)
    }

    func alias(mime: String, payload: [UInt8]) throws {
        guard let decoded = Osc5522.strictDecode(payload) else { throw Error.invalid }
        guard let text = String(bytes: decoded, encoding: .utf8) else { throw Error.invalid }
        let names = text.split { $0.isWhitespace }.compactMap { part -> String? in
            let s = String(part)
            guard !s.isEmpty, s.utf8.count <= Osc5522.maxMimeLen else { return nil }
            return s
        }
        guard !names.isEmpty else { return }
        for name in names {
            if let i = aliases.firstIndex(where: { $0.alias == name }) {
                aliases[i].target = mime
            } else if aliases.count >= Osc5522.maxWriteAliases {
                return
            } else {
                aliases.append((alias: name, target: mime))
            }
        }
    }

    func commit() throws -> [(mime: String, data: Data)] {
        if current != nil {
            try finishCurrent()
            current = nil
        }
        var contents: [(mime: String, data: Data)] = entries.map { e in
            let end = e.start + e.len
            let slice = spool[e.start..<end]
            return (e.mime, Data(slice))
        }
        for a in aliases {
            guard let target = contents.first(where: { $0.mime == a.target }) else { continue }
            if let i = contents.firstIndex(where: { $0.mime == a.alias }) {
                contents[i].data = target.data
            } else {
                contents.append((a.alias, target.data))
            }
        }
        return contents
    }

    private func finishCurrent() throws {
        try decoder.finish()
        if let idx = current {
            entries[idx].len = spool.count - entries[idx].start
        }
    }

    private func append(_ payload: [UInt8]) throws {
        let decoded: [UInt8]
        do {
            decoded = try decoder.feed(payload)
        } catch {
            throw Error.invalid
        }
        if spool.count + decoded.count > maxSize { throw Error.tooLarge }
        spool.append(contentsOf: decoded)
    }
}

final class Osc5522Writer {
    enum Phase {
        case idle
        case accumulating
        case ignoringWrites
    }

    private(set) var phase = Phase.idle
    private(set) var state: Osc5522WriteState?
    var writeAllow = true
    var pasteboard: NSPasteboard
    var maxWriteBytes = Osc5522.maxWriteBytes
    var onReply: ((Osc5522.Reply) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func reset() {
        state = nil
        phase = .idle
    }

    func handleOverflow() {
        if phase == .accumulating {
            fail(.EFBIG)
        }
    }

    func handle(meta: [UInt8], payload: [UInt8]) {
        switch Osc5522.ParseResult.parse(meta: meta, payload: payload) {
        case .drop:
            return
        case .invalid(let op, _):
            handleInvalid(op: op)
        case .packet(let packet):
            handlePacket(packet)
        }
    }

    private func handleInvalid(op: Osc5522.Op?) {
        guard phase == .accumulating else { return }
        switch op {
        case .wdata, .walias:
            fail(.EINVAL)
        default:
            break
        }
    }

    private func handlePacket(_ p: Osc5522.Packet) {
        switch p.op {
        case .read:
            return
        case .write:
            beginWrite(p)
        case .wdata:
            handleWdata(p)
        case .walias:
            handleWalias(p)
        }
    }

    private func beginWrite(_ p: Osc5522.Packet) {
        state = nil
        if p.primary {
            phase = .ignoringWrites
            reply(.ENOSYS, id: p.id)
            return
        }
        if !writeAllow {
            phase = .ignoringWrites
            reply(.EPERM, id: p.id)
            return
        }
        state = Osc5522WriteState(
            id: p.id,
            primary: p.primary,
            pw: p.pw,
            name: p.name,
            maxSize: maxWriteBytes
        )
        phase = .accumulating
    }

    private func handleWdata(_ p: Osc5522.Packet) {
        guard phase == .accumulating, let st = state else { return }
        if p.mime.isEmpty {
            commit(st)
            return
        }
        do {
            try st.data(mime: p.mime, payload: p.payload)
        } catch Osc5522WriteState.Error.tooLarge {
            fail(.EFBIG)
        } catch {
            fail(.EINVAL)
        }
    }

    private func handleWalias(_ p: Osc5522.Packet) {
        guard phase == .accumulating, let st = state else { return }
        if p.mime.isEmpty {
            fail(.EINVAL)
            return
        }
        do {
            try st.alias(mime: p.mime, payload: p.payload)
        } catch {
            fail(.EINVAL)
        }
    }

    private func commit(_ st: Osc5522WriteState) {
        let contents: [(mime: String, data: Data)]
        do {
            contents = try st.commit()
        } catch {
            fail(.EINVAL)
            return
        }
        if !writeAllow {
            fail(.EPERM)
            return
        }
        if st.primary {
            fail(.ENOSYS)
            return
        }
        if !Osc5522Pasteboard.write(pasteboard, contents: contents) {
            fail(.EIO)
            return
        }
        state = nil
        phase = .idle
        reply(.DONE, id: st.id)
    }

    private func fail(_ status: Osc5522.Status) {
        let id = state?.id ?? ""
        state = nil
        phase = .ignoringWrites
        reply(status, id: id)
    }

    private func reply(_ status: Osc5522.Status, id: String) {
        onReply?(Osc5522.Reply(op: .write, status: status, id: id))
    }
}

enum Osc5522Decision {
    case allow, always, deny, ban
}

struct Osc5522Prompt {
    var direction: Osc5522Grants.Direction
    var name: String
    var offersAlways: Bool
}

struct Osc5522Grants {
    enum Direction {
        case read, write
    }

    struct Entry {
        var pw: String
        var read = false
        var write = false
        var readBan = false
        var writeBan = false
        var oneTime = false
        var deadline: Date?
        var snapshot: [String: Data]?
    }

    static let maxEntries = 32
    var entries: [Entry] = []

    mutating func reset() {
        entries.removeAll()
    }

    mutating func grantAlways(_ pw: String, _ dir: Direction) {
        guard !pw.isEmpty else { return }
        if let i = index(of: pw, oneTime: false) {
            if dir == .read {
                entries[i].read = true
                entries[i].readBan = false
            } else {
                entries[i].write = true
                entries[i].writeBan = false
            }
            return
        }
        evictIfNeeded()
        var e = Entry(pw: pw)
        if dir == .read { e.read = true } else { e.write = true }
        entries.append(e)
    }

    mutating func ban(_ pw: String, _ dir: Direction) {
        guard !pw.isEmpty else { return }
        if let i = index(of: pw, oneTime: false) {
            if dir == .read {
                entries[i].readBan = true
                entries[i].read = false
            } else {
                entries[i].writeBan = true
                entries[i].write = false
            }
            return
        }
        evictIfNeeded()
        var e = Entry(pw: pw)
        if dir == .read { e.readBan = true } else { e.writeBan = true }
        entries.append(e)
    }

    mutating func replaceOTP(pw: String, deadline: Date, snapshot: [String: Data]? = nil) {
        entries.removeAll { $0.oneTime }
        guard !pw.isEmpty else { return }
        evictIfNeeded()
        entries.append(
            Entry(pw: pw, read: true, oneTime: true, deadline: deadline, snapshot: snapshot)
        )
    }

    func isBanned(_ pw: String, _ dir: Direction, now _: Date) -> Bool {
        guard !pw.isEmpty else { return false }
        for e in entries {
            guard Osc5522.timingSafeEqual(e.pw, pw) else { continue }
            if e.oneTime { continue }
            return dir == .read ? e.readBan : e.writeBan
        }
        return false
    }

    func hasAlways(_ pw: String, _ dir: Direction, now _: Date) -> Bool {
        guard !pw.isEmpty else { return false }
        for e in entries {
            guard Osc5522.timingSafeEqual(e.pw, pw) else { continue }
            if e.oneTime { continue }
            if dir == .read { return e.read && !e.readBan }
            return e.write && !e.writeBan
        }
        return false
    }

    mutating func use(_ pw: String, _ dir: Direction, now: Date) -> (ok: Bool, snapshot: [String: Data]?) {
        guard !pw.isEmpty, let i = index(of: pw) else { return (false, nil) }
        let e = entries[i]
        if let deadline = e.deadline, now >= deadline {
            entries.remove(at: i)
            return (false, nil)
        }
        if e.oneTime {
            entries.remove(at: i)
            let ok: Bool
            if dir == .read {
                ok = e.read && !e.readBan
            } else {
                ok = e.write && !e.writeBan
            }
            return (ok, ok ? e.snapshot : nil)
        }
        return (false, nil)
    }

    private mutating func evictIfNeeded() {
        while entries.count >= Self.maxEntries {
            entries.removeFirst()
        }
    }

    private func index(of pw: String, oneTime: Bool? = nil) -> Int? {
        for (i, e) in entries.enumerated() {
            if let oneTime, e.oneTime != oneTime { continue }
            if Osc5522.timingSafeEqual(e.pw, pw) { return i }
        }
        return nil
    }
}
