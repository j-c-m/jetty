import Darwin
import Foundation

/// Two-stage PTY drain (Ghostty Darwin Adaptive gather). Session owns the master fd.
public final class PtyPipeline: @unchecked Sendable {
    static let bufferCount = 4
    static let bufferCapacity = 64 * 1024
    static let bridgeThreshold = 1024
    static let bridgeSpinMax = 16
    static let bridgePollTimeoutMs: Int32 = 1
    static let gatherBudgetNs: UInt64 = 3_000_000

    public typealias ParseHandler = (UnsafePointer<UInt8>, Int) -> Void
    public typealias DeathHandler = () -> Void

    private let masterFD: Int32
    private let onParse: ParseHandler
    private let onDeath: DeathHandler

    private var quitReadFD: Int32 = -1
    private var quitWriteFD: Int32 = -1
    private var idleReadFD: Int32 = -1
    private var idleWriteFD: Int32 = -1

    private let slots: [UnsafeMutablePointer<UInt8>]
    private var lengths: [Int]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var done = false
    private var bridging = false
    private var streamEnded = false
    private var recoverReady = false

    private let ring = NSCondition()
    private var gatherThread: Thread?
    private var parseThread: Thread?
    private var started = false

    public init(masterFD: Int32, onParse: @escaping ParseHandler, onDeath: @escaping DeathHandler) {
        self.masterFD = masterFD
        self.onParse = onParse
        self.onDeath = onDeath
        var bufs: [UnsafeMutablePointer<UInt8>] = []
        bufs.reserveCapacity(Self.bufferCount)
        for _ in 0..<Self.bufferCount {
            bufs.append(.allocate(capacity: Self.bufferCapacity))
        }
        slots = bufs
        lengths = [Int](repeating: 0, count: Self.bufferCount)
    }

    deinit {
        stop()
        for p in slots {
            p.deallocate()
        }
    }

    @discardableResult
    public func start() -> Bool {
        ring.lock()
        if started {
            ring.unlock()
            return true
        }
        ring.unlock()

        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else {
            fputs("jetty: PtyPipeline quit pipe failed\n", stderr)
            return false
        }
        quitReadFD = fds[0]
        quitWriteFD = fds[1]
        setNonBlocking(quitReadFD)
        setNonBlocking(quitWriteFD)

        if pipe(&fds) == 0 {
            idleReadFD = fds[0]
            idleWriteFD = fds[1]
            setNonBlocking(idleReadFD)
            setNonBlocking(idleWriteFD)
        }

        let gather = Thread { [weak self] in
            self?.gatherMain()
        }
        gather.name = "jetty-io-gather"
        gather.qualityOfService = .userInteractive
        gatherThread = gather

        let parse = Thread { [weak self] in
            self?.parseMain()
        }
        parse.name = "jetty-io-parse"
        parse.qualityOfService = .userInteractive
        parseThread = parse

        ring.lock()
        started = true
        ring.unlock()

        gather.start()
        parse.start()
        return true
    }

    /// Must not be called while holding the session lock that `onParse` takes.
    public func stop() {
        ring.lock()
        guard started else {
            ring.unlock()
            return
        }
        done = true
        ring.broadcast()
        ring.unlock()

        if quitWriteFD >= 0 {
            var b: UInt8 = 1
            _ = write(quitWriteFD, &b, 1)
        }
        wakeIdle()

        gatherThread?.cancel()
        parseThread?.cancel()
        if let t = gatherThread, t !== Thread.current {
            while !t.isFinished {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        if let t = parseThread, t !== Thread.current {
            while !t.isFinished {
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        gatherThread = nil
        parseThread = nil

        closeFD(&quitReadFD)
        closeFD(&quitWriteFD)
        closeFD(&idleReadFD)
        closeFD(&idleWriteFD)

        ring.lock()
        started = false
        head = 0
        tail = 0
        count = 0
        done = false
        bridging = false
        streamEnded = false
        ring.unlock()
    }

    public func takeChildDead() -> Bool {
        ring.lock()
        defer { ring.unlock() }
        if recoverReady {
            recoverReady = false
            return true
        }
        return false
    }

    private func parseMain() {
        while true {
            let batch: (UnsafeMutablePointer<UInt8>, Int)? = {
                ring.lock()
                defer { ring.unlock() }
                while count == 0 && !done {
                    ring.wait()
                }
                if count == 0 {
                    return nil
                }
                let slot = tail
                let len = lengths[slot]
                let ptr = slots[slot]
                return (ptr, len)
            }()

            guard let (ptr, len) = batch else {
                ring.lock()
                if streamEnded {
                    recoverReady = true
                }
                ring.unlock()
                onDeath()
                return
            }

            if len > 0 {
                onParse(UnsafePointer(ptr), len)
            }

            ring.lock()
            tail = (tail + 1) % Self.bufferCount
            count -= 1
            let nowIdle = count == 0
            let wasBridging = bridging
            ring.broadcast()
            ring.unlock()

            if nowIdle && wasBridging {
                wakeIdle()
            }
        }
    }

    private func gatherMain() {
        defer {
            ring.lock()
            done = true
            ring.broadcast()
            ring.unlock()
        }

        while true {
            let slotIndex: Int = {
                ring.lock()
                defer { ring.unlock() }
                while count == Self.bufferCount && !done {
                    ring.wait()
                }
                if done { return -1 }
                return head
            }()
            if slotIndex < 0 { return }

            let buf = slots[slotIndex]
            var total = 0
            var bridgeStart: UInt64?
            var spins = 0
            var fatal = false
            var sawEOF = false

            gatherLoop: while total < Self.bufferCapacity {
                if Thread.current.isCancelled {
                    fatal = true
                    break gatherLoop
                }

                let n = read(masterFD, buf.advanced(by: total), Self.bufferCapacity - total)
                if n > 0 {
                    total += Int(n)
                    spins = 0
                    continue gatherLoop
                }
                if n == 0 {
                    sawEOF = true
                    fatal = true
                    break gatherLoop
                }

                let err = errno
                if err == EINTR {
                    continue gatherLoop
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    if total < Self.bridgeThreshold {
                        break gatherLoop
                    }
                    if spins < Self.bridgeSpinMax {
                        spins += 1
                        continue gatherLoop
                    }

                    let now = machContinuousTimeNs()
                    if let start = bridgeStart {
                        if now &- start >= Self.gatherBudgetNs {
                            break gatherLoop
                        }
                    } else {
                        bridgeStart = now
                    }

                    let shouldBridge: Bool = {
                        ring.lock()
                        defer { ring.unlock() }
                        if count == 0 { return false }
                        bridging = true
                        return true
                    }()
                    if !shouldBridge {
                        break gatherLoop
                    }

                    var pollfds = [
                        pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: quitReadFD, events: Int16(POLLIN), revents: 0),
                    ]
                    if idleReadFD >= 0 {
                        pollfds.append(pollfd(fd: idleReadFD, events: Int16(POLLIN), revents: 0))
                    }
                    let pr = poll(&pollfds, nfds_t(pollfds.count), Self.bridgePollTimeoutMs)
                    clearBridging()

                    if pr == 0 {
                        break gatherLoop
                    }
                    if pr < 0 {
                        if errno == EINTR { continue gatherLoop }
                        fatal = true
                        break gatherLoop
                    }
                    if pollfds[1].revents & Int16(POLLIN) != 0 {
                        fatal = true
                        break gatherLoop
                    }
                    if idleReadFD >= 0,
                       pollfds.count > 2,
                       pollfds[2].revents & Int16(POLLIN) != 0 {
                        drainIdle()
                        break gatherLoop
                    }
                    spins = 0
                    continue gatherLoop
                }
                if err == EIO {
                    sawEOF = true
                    fatal = true
                    break gatherLoop
                }
                fatal = true
                break gatherLoop
            }

            clearBridging()

            ring.lock()
            if total > 0 {
                lengths[slotIndex] = total
                head = (head + 1) % Self.bufferCount
                count += 1
                ring.broadcast()
            }
            if sawEOF {
                streamEnded = true
            }
            if fatal {
                done = true
                if sawEOF { streamEnded = true }
                ring.broadcast()
                ring.unlock()
                return
            }
            ring.unlock()

            if total == 0 {
                var pollfds = [
                    pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: quitReadFD, events: Int16(POLLIN), revents: 0),
                ]
                let pr = poll(&pollfds, 2, -1)
                if pr < 0 {
                    if errno == EINTR { continue }
                    ring.lock()
                    done = true
                    streamEnded = true
                    ring.broadcast()
                    ring.unlock()
                    return
                }
                if pollfds[1].revents & Int16(POLLIN) != 0 {
                    ring.lock()
                    done = true
                    ring.broadcast()
                    ring.unlock()
                    return
                }
                if pollfds[0].revents & Int16(POLLHUP) != 0 {
                    ring.lock()
                    done = true
                    streamEnded = true
                    ring.broadcast()
                    ring.unlock()
                    return
                }
            }
        }
    }

    private func clearBridging() {
        ring.lock()
        bridging = false
        ring.unlock()
    }

    private func wakeIdle() {
        guard idleWriteFD >= 0 else { return }
        var b: UInt8 = 1
        _ = write(idleWriteFD, &b, 1)
    }

    private func drainIdle() {
        guard idleReadFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        while read(idleReadFD, &buf, buf.count) > 0 {}
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func closeFD(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func machContinuousTimeNs() -> UInt64 {
        let t = mach_continuous_time()
        let tb = Self.timebase
        return t * UInt64(tb.numer) / UInt64(tb.denom)
    }
}
