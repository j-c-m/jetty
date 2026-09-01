import AppKit
import CPty
import CVt
import CoreFoundation
import Darwin
import Foundation
import os

public final class TerminalSession: @unchecked Sendable {
    public let lock = NSLock()
    public let screen: Screen
    public let parser = Parser()

    public private(set) var masterFD: Int32 = -1
    public private(set) var childPID: pid_t = 0
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32

    private var pipeline: PtyPipeline?
    private let ptyOut = DispatchQueue(label: "dev.jetty.pty.out", qos: .userInteractive)
    private let ptyOutStop = OSAllocatedUnfairLock(uncheckedState: false)
    private struct Osc5522HopQueue {
        var queuedBytes = 0
        var overflowArmed = false
    }
    private let osc5522Hop = OSAllocatedUnfairLock(uncheckedState: Osc5522HopQueue())
    let osc5522Writer = Osc5522Writer()
    var osc5522ReplySink: (([UInt8]) -> Void)?
    var osc5522Grants = Osc5522Grants()
    var storedPasswords: Osc5522StoredPasswords?
    var osc5522Now: () -> Date = Date.init
    var osc5522MaxReadBytes = Osc5522.maxReadBytes
    var dataReplyInFlight = false
    var dataReplyGen: UInt64 = 0
    var osc5522PromptOpen = false
    var osc5522PromptGen: UInt64 = 0
    var onOsc5522Prompt: ((Osc5522Prompt, @escaping (Osc5522Decision) -> Void) -> Void)?
    public var onRedraw: (@Sendable () -> Void)?
    public var onDeath: (@Sendable () -> Void)?
    public var onTitle: (@Sendable (String) -> Void)?
    public var osc52WriteAllow = true
    public var osc52ReadAsk = true
    public var desktopNotifications = true
    public var isNotifyFocused: (@Sendable () -> Bool)?
    public var onProgress: (@Sendable (UInt8, UInt8) -> Void)?
    public var notifyOnCommandFinish: AppConfig.NotifyWhen = .never
    public var notifyOnCommandFinishAfter: TimeInterval = 5
    public var notifyOnCommandFinishBell = true
    public var notifyOnCommandFinishDesktop = false
    var commandStartedAt: Date?
    public private(set) var osc7: String = ""
    public var title: String {
        lock.lock()
        let t = windowTitle
        lock.unlock()
        return t
    }
    private var windowTitle = "Jetty"
    private var titleStack: [String] = []
    /// Process cwd at spawn; used until OSC 7 reports a path.
    private var spawnDirectory = ""
    public private(set) var osc133: [(line: UInt64, action: UInt8, opts: [UInt8])] = []

    private let redrawLock = NSLock()
    private var redrawPending = false
    private var drawDemand: Int32 = 0
    private let handoff = NSCondition()
    private var syncTimeoutWork: DispatchWorkItem?
    private var lastSyncEpoch: UInt32 = 0
    private var lastSyncOn = false

    public init(
        cols: Int = 105,
        rows: Int = 35,
        cellWidthPx: UInt32 = 12,
        cellHeightPx: UInt32 = 24,
        scrollbackCapRows: Int = 50_000
    ) {
        self.screen = Screen(cols: cols, rows: rows, scrollbackCapRows: scrollbackCapRows)
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        screen.setCellPx(width: cellWidthPx, height: cellHeightPx)
        parser.screen = screen
        parser.ptyWriter = { [weak self] bytes in
            self?.writeToPty(bytes)
        }
        parser.onTitle = { [weak self] title in
            self?.windowTitle = title
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onTitle?(title) }
            }
        }
        parser.onOsc52Write = { [weak self] _, b64 in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyOsc52Write(b64) }
            }
        }
        parser.onOsc52Read = { [weak self] kind in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.askOsc52Read(kind) }
            }
        }
        osc5522Writer.onReply = { [weak self] reply in
            let bytes = reply.bytes()
            self?.osc5522ReplySink?(bytes)
            self?.writeToPty(bytes)
        }
        parser.onOsc5522 = { [weak self] meta, payload in
            self?.hopOsc5522(meta: meta, payload: payload)
        }
        parser.onPaletteChanged = { [weak self] in
            self?.scheduleRedraw()
        }
        parser.onOsc7 = { [weak self] uri in
            self?.osc7 = uri
        }
        parser.onOsc133 = { [weak self] action, opts in
            guard let self else { return }
            if self.screen.inAlt { return }
            let line = self.screen.linesScrolled + UInt64(max(0, self.screen.cursorY))
            self.osc133.append((line, action, opts))
            if self.osc133.count > 4096 { self.osc133.removeFirst(self.osc133.count - 4096) }
            self.noteCommandMark(action: action, opts: opts)
        }
        parser.onHistoryCleared = { [weak self] in
            self?.osc133.removeAll()
            self?.commandStartedAt = nil
        }
        parser.onSizeReport = { [weak self] kind in
            self?.replySizeReport(kind)
        }
        parser.onProgress = { [weak self] state, percent in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onProgress?(state, percent) }
            }
        }
        parser.onNotify = { [weak self] title, body in
            let subtitle = self?.windowTitle ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.deliverNotify(title: title, body: body, subtitle: subtitle)
                }
            }
        }
    }

    public var workingDirectory: String {
        lock.lock()
        let uri = osc7
        let spawn = spawnDirectory
        lock.unlock()
        let fromOsc = Self.pathFromOSC7(uri)
        return fromOsc.isEmpty ? spawn : fromOsc
    }

    /// Directory for a new window: OSC 7, else the session shell cwd, else spawn.
    public func inheritWorkingDirectory() -> String {
        lock.lock()
        let uri = osc7
        let spawn = spawnDirectory
        let pid = childPID
        let fd = masterFD
        lock.unlock()
        let osc = Self.pathFromOSC7(uri)
        if let path = Self.existingDirectory(osc) { return path }
        if pid > 0 || fd >= 0 {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            if jt_pty_session_cwd(fd, pid, &buf, buf.count) == 0 {
                let n = buf.firstIndex(of: 0) ?? buf.count
                let live = String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if let path = Self.existingDirectory(live) { return path }
            }
        }
        return Self.existingDirectory(spawn) ?? ""
    }

    /// True if the PTY child or a descendant is not login / a shell.
    public var hasNonShellProcess: Bool {
        lock.lock()
        let pid = childPID
        let fd = masterFD
        lock.unlock()
        return jt_pty_has_nonshell(fd, pid) != 0
    }

    public var ttyName: String {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        var buf = [CChar](repeating: 0, count: 128)
        guard jt_pty_ttyname(fd, &buf, buf.count) == 0 else { return "" }
        let n = buf.firstIndex(of: 0) ?? buf.count
        return String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func pathFromOSC7(_ uri: String) -> String {
        let kitty = "kitty-shell-cwd://"
        if uri.hasPrefix(kitty) {
            let rest = uri.dropFirst(kitty.count)
            if let slash = rest.firstIndex(of: "/") {
                return dropTrailingSlash(String(rest[slash...]))
            }
            return ""
        }
        let file = "file://"
        if uri.hasPrefix(file) {
            let rest = uri.dropFirst(file.count)
            guard let slash = rest.firstIndex(of: "/") else { return "" }
            return dropTrailingSlash(percentDecodePath(String(rest[slash...])))
        }
        return ""
    }

    private static func dropTrailingSlash(_ path: String) -> String {
        if path.count > 1, path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }

    /// Fish OSC 7 url-escapes `$PWD`. Invalid `%` sequences stay literal.
    static func percentDecodePath(_ s: String) -> String {
        let u = Array(s.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "%"), i + 2 < u.count,
               let hi = hexNibble(u[i + 1]), let lo = hexNibble(u[i + 2])
            {
                bytes.append((hi << 4) | lo)
                i += 3
                continue
            }
            bytes.append(u[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private func noteCommandMark(action: UInt8, opts: [UInt8]) {
        if action == UInt8(ascii: "C") {
            commandStartedAt = Date()
            return
        }
        guard action == UInt8(ascii: "D") else { return }
        guard let start = commandStartedAt else { return }
        commandStartedAt = nil
        let when = notifyOnCommandFinish
        if when == .never { return }
        let dur = Date().timeIntervalSince(start)
        if dur < notifyOnCommandFinishAfter { return }
        let exit = CommandOutput.exitCode(opts: opts)
        let bell = notifyOnCommandFinishBell
        let desktop = notifyOnCommandFinishDesktop
        let title = windowTitle
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let focused = self.isNotifyFocused?() ?? false
            if when == .unfocused, focused { return }
            if bell { NSSound.beep() }
            if desktop {
                var body = "finished in \(Int(dur.rounded()))s"
                if let exit {
                    body = "exit \(exit), " + body
                }
                DesktopNotify.post(title: "Command finished", body: body, subtitle: title)
            }
        }
    }

    private static func existingDirectory(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return path
    }

    private static func defaultSpawnDirectory() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        if cwd != "/" { return cwd }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    @discardableResult
    public func spawn(
        workingDirectory: String? = nil,
        extraEnv: [String] = [],
        command: String? = nil
    ) -> Bool {
        var pid: pid_t = 0
        let fd: Int32
        let envPtrs = extraEnv.map { strdup($0) }
        defer { envPtrs.forEach { if let p = $0 { free(p) } } }
        var envList: [UnsafePointer<CChar>?] = envPtrs.map { $0.map { UnsafePointer($0) } }
        envList.append(nil)
        let cmd = command.flatMap { $0.isEmpty ? nil : $0 }
        fd = envList.withUnsafeBufferPointer { envBuf in
            let envP = extraEnv.isEmpty ? nil : envBuf.baseAddress
            func call(_ cwd: UnsafePointer<CChar>?, _ command: UnsafePointer<CChar>?) -> Int32 {
                jt_pty_spawn_ex(
                    UInt16(screen.cols), UInt16(screen.rows),
                    cellWidthPx, cellHeightPx, cwd, envP, command, &pid
                )
            }
            func withCwd(_ command: UnsafePointer<CChar>?) -> Int32 {
                if let workingDirectory, !workingDirectory.isEmpty {
                    return workingDirectory.withCString { call($0, command) }
                }
                return call(nil, command)
            }
            if let cmd {
                return cmd.withCString { withCwd($0) }
            }
            return withCwd(nil)
        }
        guard fd >= 0 else { return false }
        let remembered: String
        if let workingDirectory, !workingDirectory.isEmpty {
            remembered = workingDirectory
        } else {
            remembered = Self.defaultSpawnDirectory()
        }
        lock.lock()
        masterFD = fd
        childPID = pid
        spawnDirectory = remembered
        lock.unlock()
        ptyOutStop.withLock { $0 = false }
        let pipe = PtyPipeline(masterFD: fd, onParse: { [weak self] ptr, len in
            self?.parseBatch(ptr, len)
        }, onDeath: { [weak self] in
            self?.childDied()
        })
        pipeline = pipe
        return pipe.start()
    }

    public func stop() {
        pipeline?.stop()
        pipeline = nil
        ptyOutStop.withLock { $0 = true }
        lock.lock()
        let fd = masterFD
        masterFD = -1
        let pid = childPID
        childPID = 0
        lock.unlock()
        if fd >= 0 { close(fd) }
        ptyOut.sync {}
        osc5522Writer.reset()
        osc5522Grants.reset()
        dataReplyGen += 1
        dataReplyInFlight = false
        osc5522PromptGen += 1
        osc5522PromptOpen = false
        if pid > 0 {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    public func setWinsize(cols: Int, rows: Int) {
        lock.lock()
        parser.syncDrop()
        screen.resize(cols: cols, rows: rows)
        lastSyncOn = false
        lastSyncEpoch = 0
        cancelSyncTimeout()
        let fd = masterFD
        let cw = cellWidthPx
        let ch = cellHeightPx
        let reportCols = screen.cols
        let reportRows = screen.rows
        let inband = screen.implPtr.pointee.inband_size != 0
        lock.unlock()
        if fd >= 0 {
            _ = jt_pty_set_winsize(fd, UInt16(max(2, cols)), UInt16(max(1, rows)), cw, ch)
        }
        if inband {
            parser.ptyWriter?(Array(inbandSizeSequence(cols: reportCols, rows: reportRows).utf8))
        }
        scheduleRedraw()
    }

    private func replySizeReport(_ kind: Int32) {
        let cols = screen.cols
        let rows = screen.rows
        let cw = Int(cellWidthPx)
        let ch = Int(cellHeightPx)
        let seq: String
        if kind == 14 {
            seq = "\u{1B}[4;\(rows * ch);\(cols * cw)t"
        } else if kind == 16 {
            seq = "\u{1B}[6;\(ch);\(cw)t"
        } else if kind == 18 {
            seq = "\u{1B}[8;\(rows);\(cols)t"
        } else if kind == 48 {
            seq = inbandSizeSequence(cols: cols, rows: rows)
        } else if kind == 22 {
            if titleStack.count < 8 { titleStack.append(windowTitle) }
            return
        } else if kind == 23 {
            if let t = titleStack.popLast() {
                windowTitle = t
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onTitle?(t) }
                }
            }
            return
        } else {
            return
        }
        parser.ptyWriter?(Array(seq.utf8))
    }

    private func inbandSizeSequence(cols: Int, rows: Int) -> String {
        let r = max(1, rows)
        let c = max(2, cols)
        let hp = r * Int(cellHeightPx)
        let wp = c * Int(cellWidthPx)
        return "\u{1B}[48;\(r);\(c);\(hp);\(wp)t"
    }

    @MainActor
    private func deliverNotify(title: String, body: String, subtitle: String) {
        guard desktopNotifications else { return }
        if isNotifyFocused?() == true { return }
        DesktopNotify.post(title: title, body: body, subtitle: subtitle)
    }

    @MainActor
    private func applyOsc52Write(_ b64: [UInt8]) {
        guard osc52WriteAllow else { return }
        let raw = String(bytes: b64, encoding: .ascii) ?? ""
        let clean = String(raw.filter { !$0.isWhitespace && $0 != "\n" && $0 != "\r" })
        guard let data = Data(base64Encoded: clean),
              let text = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    private func askOsc52Read(_ kind: UInt8) {
        let k = kind == 0 ? UInt8(ascii: "c") : kind
        func reply(_ payload: String) {
            var out = Array("\u{1B}]52;".utf8)
            out.append(k)
            out.append(UInt8(ascii: ";"))
            out.append(contentsOf: payload.utf8)
            out.append(0x07)
            writeToPty(out)
        }
        if !osc52ReadAsk {
            reply("")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow clipboard read?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let ok = alert.runModal() == .alertFirstButtonReturn
        guard ok, let str = NSPasteboard.general.string(forType: .string) else {
            reply("")
            return
        }
        reply(Data(str.utf8).base64EncodedString())
    }

    public func writeToPty(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if ptyOutStop.withLock({ $0 }) { return }
        let copy = bytes
        ptyOut.async { [weak self] in
            guard let self else { return }
            if self.ptyOutStop.withLock({ $0 }) { return }
            self.lock.lock()
            let fd = self.masterFD
            self.lock.unlock()
            guard fd >= 0 else { return }
            _ = writePtyBlocking(fd: fd, copy)
        }
    }

    private func hopOsc5522(meta: [UInt8], payload: [UInt8]) {
        enum Hop {
            case drop
            case overflow
            case packet(Int)
        }
        let hop: Hop = osc5522Hop.withLock { q in
            if q.overflowArmed { return .drop }
            let quantum = max(meta.count + payload.count, Osc5522.queueQuantum)
            if q.queuedBytes + quantum > Osc5522.maxQueuedBytes {
                q.overflowArmed = true
                q.queuedBytes += Osc5522.queueQuantum
                return .overflow
            }
            q.queuedBytes += quantum
            return .packet(quantum)
        }
        switch hop {
        case .drop:
            return
        case .overflow:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handleOsc5522Overflow() }
            }
        case .packet(let quantum):
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleOsc5522(meta: meta, payload: payload, quantum: quantum)
                }
            }
        }
    }

    @MainActor
    func handleOsc5522(meta: [UInt8], payload: [UInt8], quantum: Int) {
        defer { releaseOsc5522Quantum(quantum) }
        if ptyOutStop.withLock({ $0 }) { return }
        osc5522Writer.writeAllow = osc52WriteAllow
        if case .packet(let p) = Osc5522.ParseResult.parse(meta: meta, payload: payload),
           p.op == .read
        {
            handleOsc5522Read(p)
            return
        }
        osc5522Writer.handle(meta: meta, payload: payload)
    }

    @MainActor
    func handleOsc5522Overflow() {
        defer { releaseOsc5522Quantum(Osc5522.queueQuantum) }
        if ptyOutStop.withLock({ $0 }) { return }
        if osc5522Writer.phase == .accumulating {
            osc5522Writer.handleOverflow()
            return
        }
        if dataReplyInFlight {
            emitOsc5522(Osc5522.Reply(op: .read, status: .EBUSY).bytes())
        }
    }

    private func releaseOsc5522Quantum(_ quantum: Int) {
        osc5522Hop.withLock { q in
            q.queuedBytes = max(0, q.queuedBytes - quantum)
            if q.queuedBytes == 0 { q.overflowArmed = false }
        }
    }

    @discardableResult
    func installPasteOTP(
        pw: String? = nil,
        deadline: Date? = nil,
        snapshot: [String: Data]? = nil
    ) -> String {
        let otp = pw ?? Osc5522.randomOTP()
        osc5522Grants.replaceOTP(
            pw: otp,
            deadline: deadline ?? osc5522Now().addingTimeInterval(Osc5522.otpTimeout),
            snapshot: snapshot
        )
        return otp
    }

    @discardableResult
    func sendPasteEvent(from pb: NSPasteboard, snapshot: Bool) -> Bool {
        if dataReplyInFlight { return false }
        let mimes = Osc5522Pasteboard.available(pb)
        var snap: [String: Data]?
        if snapshot {
            var remaining = osc5522MaxReadBytes
            var captured: [String: Data] = [:]
            for mime in mimes {
                guard remaining > 0 else { break }
                guard var d = Osc5522Pasteboard.data(pb, mime: mime), !d.isEmpty else { continue }
                if d.count > remaining { d = d.prefix(remaining) }
                remaining -= d.count
                captured[mime] = d
            }
            snap = captured
        }
        let otp = Osc5522.randomOTP()
        osc5522Grants.replaceOTP(
            pw: otp,
            deadline: osc5522Now().addingTimeInterval(Osc5522.otpTimeout),
            snapshot: snap
        )
        let payload = Osc5522.listingPayload(mimes)
        emitOsc5522(Osc5522.Reply(op: .read, status: .OK, pw: otp).bytes())
        emitOsc5522(
            Osc5522.Reply(op: .read, status: .DATA, mime: Osc5522.targetsMime, pw: otp, payload: payload)
                .bytes()
        )
        emitOsc5522(Osc5522.Reply(op: .read, status: .DONE, pw: otp).bytes())
        return true
    }

    func clearDataReplyIfCurrent(gen: UInt64) {
        if dataReplyGen == gen { dataReplyInFlight = false }
    }

    @MainActor
    private func handleOsc5522Read(_ p: Osc5522.Packet, skipPrompt: Bool = false) {
        guard let list = Osc5522.parseReadList(p.payload) else { return }
        if p.primary {
            if !p.pw.isEmpty, !p.name.isEmpty {
                _ = osc5522Grants.use(p.pw, .read, now: osc5522Now())
            }
            emitOsc5522(Osc5522.Reply(op: .read, status: .ENOSYS, id: p.id).bytes())
            return
        }
        if !osc52ReadAsk {
            emitOsc5522(Osc5522.Reply(op: .read, status: .EPERM, id: p.id).bytes())
            return
        }
        if list.wantListing && list.mimes.isEmpty {
            serveOsc5522Listing(id: p.id)
            return
        }
        let now = osc5522Now()
        if !p.pw.isEmpty, osc5522Grants.isBanned(p.pw, .read, now: now) {
            emitOsc5522(Osc5522.Reply(op: .read, status: .EPERM, id: p.id).bytes())
            return
        }
        if dataReplyInFlight {
            emitOsc5522(Osc5522.Reply(op: .read, status: .EBUSY, id: p.id).bytes())
            return
        }
        if skipPrompt {
            serveOsc5522Read(p, list: list, snapshot: nil)
            return
        }
        if !p.pw.isEmpty, osc5522Grants.hasAlways(p.pw, .read, now: now) {
            serveOsc5522Read(p, list: list, snapshot: nil)
            return
        }
        if (storedPasswords ?? Osc5522StoredPasswords.process)
            .match(name: p.name, password: p.pw)
        {
            serveOsc5522Read(p, list: list, snapshot: nil)
            return
        }
        if !p.pw.isEmpty, !p.name.isEmpty {
            let used = osc5522Grants.use(p.pw, .read, now: now)
            if used.ok {
                serveOsc5522Read(p, list: list, snapshot: used.snapshot)
                return
            }
        }
        if osc5522PromptOpen {
            emitOsc5522(Osc5522.Reply(op: .read, status: .EBUSY, id: p.id).bytes())
            return
        }
        presentOsc5522ReadPrompt(p)
    }

    @MainActor
    private func presentOsc5522ReadPrompt(_ p: Osc5522.Packet) {
        guard let promptFn = onOsc5522Prompt else {
            emitOsc5522(Osc5522.Reply(op: .read, status: .EPERM, id: p.id).bytes())
            return
        }
        osc5522PromptOpen = true
        osc5522PromptGen += 1
        let gen = osc5522PromptGen
        let prompt = Osc5522Prompt(
            direction: .read,
            name: Osc5522.sanitizeName(p.name),
            offersAlways: !p.pw.isEmpty && !p.name.isEmpty
        )
        promptFn(prompt) { [weak self] decision in
            let run = {
                self?.finishOsc5522ReadPrompt(gen: gen, packet: p, decision: decision)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(run)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(run) }
            }
        }
    }

    @MainActor
    private func finishOsc5522ReadPrompt(
        gen: UInt64,
        packet: Osc5522.Packet,
        decision: Osc5522Decision
    ) {
        guard gen == osc5522PromptGen else { return }
        osc5522PromptOpen = false
        switch decision {
        case .deny:
            emitOsc5522(Osc5522.Reply(op: .read, status: .EPERM, id: packet.id).bytes())
        case .ban:
            osc5522Grants.ban(packet.pw, .read)
            emitOsc5522(Osc5522.Reply(op: .read, status: .EPERM, id: packet.id).bytes())
        case .always:
            osc5522Grants.grantAlways(packet.pw, .read)
            handleOsc5522Read(packet, skipPrompt: true)
        case .allow:
            handleOsc5522Read(packet, skipPrompt: true)
        }
    }

    @MainActor
    private func serveOsc5522Listing(id: String) {
        let mimes = Osc5522Pasteboard.available(osc5522Writer.pasteboard)
        let payload = Osc5522.listingPayload(mimes)
        emitOsc5522(Osc5522.Reply(op: .read, status: .OK, id: id).bytes())
        emitOsc5522(
            Osc5522.Reply(
                op: .read, status: .DATA, id: id, mime: Osc5522.targetsMime, payload: payload
            ).bytes()
        )
        emitOsc5522(Osc5522.Reply(op: .read, status: .DONE, id: id).bytes())
    }

    @MainActor
    private func serveOsc5522Read(
        _ p: Osc5522.Packet,
        list: Osc5522.ReadList,
        snapshot: [String: Data]?
    ) {
        var remaining = osc5522MaxReadBytes
        let pb = osc5522Writer.pasteboard
        var listing: Data?
        if list.wantListing {
            let names = Osc5522Pasteboard.available(pb)
            listing = Data(Osc5522.listingPayload(names))
        }
        var parts: [(mime: String, data: Data)] = []
        for mime in list.mimes {
            guard remaining > 0 else { break }
            let raw: Data?
            if let snapshot {
                raw = snapshot[mime]
            } else {
                raw = Osc5522Pasteboard.data(pb, mime: mime)
            }
            guard let raw, !raw.isEmpty else { continue }
            let slice: Data = raw.count > remaining ? raw.prefix(remaining) : raw
            remaining -= slice.count
            parts.append((mime, slice))
        }
        dataReplyGen += 1
        let gen = dataReplyGen
        dataReplyInFlight = true
        let id = p.id
        emitOsc5522Encoded {
            Osc5522.Reply(op: .read, status: .OK, id: id).bytes()
        }
        if list.wantListing {
            let listing = listing ?? Data()
            emitOsc5522Encoded {
                Osc5522.Reply(
                    op: .read,
                    status: .DATA,
                    id: id,
                    mime: Osc5522.targetsMime,
                    payload: [UInt8](listing)
                ).bytes()
            }
        }
        for part in parts {
            var off = 0
            while off < part.data.count {
                let end = min(off + Osc5522.readChunk, part.data.count)
                let chunk = part.data.subdata(in: off..<end)
                emitOsc5522Encoded {
                    Osc5522.Reply(
                        op: .read, status: .DATA, id: id, mime: part.mime, payload: [UInt8](chunk)
                    ).bytes()
                }
                off = end
            }
        }
        emitOsc5522Encoded {
            Osc5522.Reply(op: .read, status: .DONE, id: id).bytes()
        }
        ptyOut.async { [weak self] in
            DispatchQueue.main.async {
                self?.clearDataReplyIfCurrent(gen: gen)
            }
        }
    }

    private func emitOsc5522(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        osc5522ReplySink?(bytes)
        writeToPty(bytes)
    }

    private func emitOsc5522Encoded(_ make: @escaping @Sendable () -> [UInt8]) {
        if ptyOutStop.withLock({ $0 }) { return }
        ptyOut.async { [weak self] in
            guard let self else { return }
            if self.ptyOutStop.withLock({ $0 }) { return }
            let bytes = make()
            guard !bytes.isEmpty else { return }
            self.osc5522ReplySink?(bytes)
            self.lock.lock()
            let fd = self.masterFD
            self.lock.unlock()
            guard fd >= 0 else { return }
            _ = writePtyBlocking(fd: fd, bytes)
        }
    }

    public func lockDemand() {
        withUnsafeMutablePointer(to: &drawDemand) { _ = jt_atomic_i32_add($0, 1) }
        lock.lock()
    }

    /// Present path. If parse holds the lock, skip this vsync instead of hanging.
    public func tryLockDemand() -> Bool {
        guard lock.`try`() else { return false }
        withUnsafeMutablePointer(to: &drawDemand) { _ = jt_atomic_i32_add($0, 1) }
        return true
    }

    public func unlockDemand() {
        lock.unlock()
        withUnsafeMutablePointer(to: &drawDemand) { _ = jt_atomic_i32_add($0, -1) }
        handoff.lock()
        handoff.broadcast()
        handoff.unlock()
    }

    private static let parseSliceBytes = 64 * 1024
    private static let parseBudgetNs: UInt64 = 1_000_000

    private func parseBatch(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
        var off = 0
        var needRedraw = false
        lock.lock()
        parser.unlockForIO = { [unowned self] in self.lock.unlock() }
        parser.relock = { [unowned self] in self.lock.lock() }
        var t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while off < len {
            let n = min(Self.parseSliceBytes, len - off)
            parser.feed(ptr.advanced(by: off), count: n)
            off += n
            syncAfterFeed()
            if parser.syncBytes < n { needRedraw = true }
            if off >= len { break }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let budget = now &- t0 >= Self.parseBudgetNs
            if drawWaiting() {
                if needRedraw { scheduleRedraw() }
                lock.unlock()
                yieldToDemand()
                lock.lock()
                needRedraw = false
                t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            } else if budget {
                if needRedraw { scheduleRedraw() }
                t0 = now
            }
        }
        parser.unlockForIO = nil
        parser.relock = nil
        lock.unlock()
        if needRedraw { scheduleRedraw() }
    }

    private func syncAfterFeed() {
        let on = screen.syncOutput
        let ep = jt_sync_epoch(screen.implPtr)
        if on {
            if ep != lastSyncEpoch {
                lastSyncEpoch = ep
                armSyncTimeout(epoch: ep)
            }
        } else if lastSyncOn {
            cancelSyncTimeout()
        }
        lastSyncOn = on
    }

    private func armSyncTimeout(epoch: UInt32) {
        cancelSyncTimeout()
        let work = DispatchWorkItem { [weak self] in
            self?.syncTimeoutFired(epoch: epoch)
        }
        syncTimeoutWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(Dec2026.timeoutNs / 1_000_000)),
            execute: work
        )
    }

    private func cancelSyncTimeout() {
        syncTimeoutWork?.cancel()
        syncTimeoutWork = nil
    }

    private func syncTimeoutFired(epoch: UInt32) {
        lock.lock()
        let fire = jt_sync_epoch(screen.implPtr) == epoch && screen.syncOutput
        if fire {
            parser.syncTimeout()
            lastSyncOn = false
            syncTimeoutWork = nil
        }
        lock.unlock()
        if fire { scheduleRedraw() }
    }

    private func drawWaiting() -> Bool {
        withUnsafeMutablePointer(to: &drawDemand) { jt_atomic_i32_load($0) } != 0
    }

    private func yieldToDemand() {
        handoff.lock()
        _ = handoff.wait(until: Date().addingTimeInterval(0.001))
        handoff.unlock()
    }

    private func childDied() {
        let cb = onDeath
        DispatchQueue.main.async { cb?() }
    }

    private func scheduleRedraw() {
        redrawLock.lock()
        if redrawPending {
            redrawLock.unlock()
            return
        }
        redrawPending = true
        redrawLock.unlock()
        let cb = onRedraw
        let rl = CFRunLoopGetMain()
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.redrawLock.lock()
            self?.redrawPending = false
            self?.redrawLock.unlock()
            cb?()
        }
        CFRunLoopWakeUp(rl)
    }
}
