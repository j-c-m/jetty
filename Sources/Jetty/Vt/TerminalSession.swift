import AppKit
import CPty
import CoreFoundation
import Darwin
import Foundation

public final class TerminalSession: @unchecked Sendable {
    public let lock = NSLock()
    public let screen: Screen
    public let parser = Parser()

    public private(set) var masterFD: Int32 = -1
    public private(set) var childPID: pid_t = 0
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32

    private var pipeline: PtyPipeline?
    public var onRedraw: (@Sendable () -> Void)?
    public var onDeath: (@Sendable () -> Void)?
    public var onTitle: (@Sendable (String) -> Void)?
    public var osc52WriteAllow = true
    public var osc52ReadAsk = true
    public var desktopNotifications = true
    public var isNotifyFocused: (@Sendable () -> Bool)?
    public var onProgress: (@Sendable (UInt8, UInt8) -> Void)?
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
        }
        parser.onHistoryCleared = { [weak self] in
            self?.osc133.removeAll()
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
        guard uri.hasPrefix("file:"), let url = URL(string: uri), url.isFileURL else { return "" }
        return url.path
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
    public func spawn(workingDirectory: String? = nil) -> Bool {
        var pid: pid_t = 0
        let fd: Int32
        if let workingDirectory, !workingDirectory.isEmpty {
            fd = workingDirectory.withCString { cwd in
                jt_pty_spawn_ex(
                    UInt16(screen.cols), UInt16(screen.rows),
                    cellWidthPx, cellHeightPx, cwd, &pid
                )
            }
        } else {
            fd = jt_pty_spawn_ex(
                UInt16(screen.cols), UInt16(screen.rows),
                cellWidthPx, cellHeightPx, nil, &pid
            )
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
        lock.lock()
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        let pid = childPID
        childPID = 0
        lock.unlock()
        if pid > 0 {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }

    public func setWinsize(cols: Int, rows: Int) {
        lock.lock()
        screen.resize(cols: cols, rows: rows)
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
        let fd = masterFD
        guard fd >= 0, !bytes.isEmpty else { return }
        _ = writePtyBlocking(fd: fd, bytes)
    }

    public func lockDemand() {
        withUnsafeMutablePointer(to: &drawDemand) { _ = jt_atomic_i32_add($0, 1) }
        lock.lock()
    }

    public func unlockDemand() {
        lock.unlock()
        withUnsafeMutablePointer(to: &drawDemand) { _ = jt_atomic_i32_add($0, -1) }
        handoff.lock()
        handoff.broadcast()
        handoff.unlock()
    }

    private static let parseSliceBytes = 4096
    private static let parseBudgetNs: UInt64 = 1_000_000

    private func parseBatch(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
        var off = 0
        lock.lock()
        var t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while off < len {
            let n = min(Self.parseSliceBytes, len - off)
            parser.feed(ptr.advanced(by: off), count: n)
            off += n
            if off >= len { break }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let budget = now &- t0 >= Self.parseBudgetNs
            if drawWaiting() {
                scheduleRedraw()
                lock.unlock()
                yieldToDemand()
                lock.lock()
                t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            } else if budget {
                scheduleRedraw()
                t0 = now
            }
        }
        lock.unlock()
        scheduleRedraw()
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
