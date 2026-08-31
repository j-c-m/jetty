import Foundation

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
