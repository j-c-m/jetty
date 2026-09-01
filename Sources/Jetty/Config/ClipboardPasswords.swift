import Foundation

public struct Osc5522StoredPasswords: Sendable, Equatable {
    public struct Record: Sendable, Equatable {
        public var name: String
        public var password: String
    }

    public static let maxRecords = 32
    nonisolated(unsafe) public static var process = Osc5522StoredPasswords()

    public var records: [Record] = []

    public init(records: [Record] = []) {
        self.records = records
    }

    public static func parse(_ text: String) -> Osc5522StoredPasswords {
        var pendingName: String?
        var pendingPassword: String?
        var order: [String] = []
        var map: [String: String] = [:]

        func upsert(name: String, password: String) {
            let trimmedName = Osc5522.sanitizeName(name)
            let pw = truncateUtf8(password, Osc5522.maxPwLen)
            guard !trimmedName.isEmpty, !pw.isEmpty else { return }
            if map[trimmedName] == nil {
                order.append(trimmedName)
            }
            map[trimmedName] = pw
        }

        func flush() {
            if let name = pendingName, let password = pendingPassword {
                upsert(name: name, password: password)
            }
            pendingName = nil
            pendingPassword = nil
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "name":
                flush()
                pendingName = parts[1]
                pendingPassword = nil
            case "password":
                pendingPassword = parts[1]
            default:
                break
            }
        }
        flush()
        while order.count > maxRecords {
            let old = order.removeFirst()
            map.removeValue(forKey: old)
        }
        return Osc5522StoredPasswords(
            records: order.map { Record(name: $0, password: map[$0]!) }
        )
    }

    public static func load(from url: URL = AppConfig.clipboardPasswordsURL()) -> Osc5522StoredPasswords {
        let path = url.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return Osc5522StoredPasswords() }
        if let perms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber,
           (perms.uint16Value & 0o077) != 0
        {
            fputs("jetty: clipboard-passwords is group/other-readable; setting mode 0600\n", stderr)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Osc5522StoredPasswords()
        }
        return parse(text)
    }

    public func match(name: String, password: String) -> Bool {
        let n = Osc5522.sanitizeName(name)
        guard !n.isEmpty, !password.isEmpty else { return false }
        for rec in records {
            if rec.name.utf8.elementsEqual(n.utf8) {
                return Osc5522.timingSafeEqual(rec.password, password)
            }
        }
        return false
    }
}

private func truncateUtf8(_ s: String, _ max: Int) -> String {
    if s.utf8.count <= max { return s }
    var bytes = Array(s.utf8.prefix(max))
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
        bytes.removeLast()
    }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}
