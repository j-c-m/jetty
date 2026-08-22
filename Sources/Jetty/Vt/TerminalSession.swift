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
    }

    @discardableResult
    public func spawn() -> Bool {
        var pid: pid_t = 0
        let fd = jt_pty_spawn(
            UInt16(screen.cols), UInt16(screen.rows),
            cellWidthPx, cellHeightPx, &pid
        )
        guard fd >= 0 else { return false }
        masterFD = fd
        childPID = pid
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
        lock.unlock()
        if fd >= 0 {
            _ = jt_pty_set_winsize(fd, UInt16(max(2, cols)), UInt16(max(1, rows)), cw, ch)
        }
        scheduleRedraw()
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
            if now &- t0 >= Self.parseBudgetNs || drawWaiting() {
                scheduleRedraw()
                lock.unlock()
                yieldToDemand()
                lock.lock()
                t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
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
