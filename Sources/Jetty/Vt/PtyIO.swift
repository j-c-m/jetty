import CPty
import Darwin

public enum Terminfo {
    public static let termName = "xterm-256color"
}

public enum Pty {
    /// Placeholder cell px until Core Text metrics exist (font size 20).
    public static let stubCellWidthPx: UInt32 = 12
    public static let stubCellHeightPx: UInt32 = 24
    public static let stubCols: UInt16 = 105
    public static let stubRows: UInt16 = 35

    public static func spawn(
        cols: UInt16 = stubCols,
        rows: UInt16 = stubRows,
        cellWidthPx: UInt32 = stubCellWidthPx,
        cellHeightPx: UInt32 = stubCellHeightPx
    ) -> (fd: Int32, pid: pid_t)? {
        var pid: pid_t = 0
        let fd = jt_pty_spawn(cols, rows, cellWidthPx, cellHeightPx, &pid)
        guard fd >= 0 else { return nil }
        return (fd, pid)
    }

    public static func setWinsize(
        fd: Int32,
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) -> Int32 {
        jt_pty_set_winsize(fd, cols, rows, cellWidthPx, cellHeightPx)
    }
}

@discardableResult
public func writePtyBlocking(fd: Int32, bytes: UnsafePointer<UInt8>, len: Int) -> Int {
    var written = 0
    var pollfds = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
    while written < len {
        let n = jt_pty_write(fd, bytes.advanced(by: written), len - written)
        if n > 0 {
            written += Int(n)
            continue
        }
        if n < 0 { return written }
        let pr = poll(&pollfds, 1, 250)
        if pr < 0 {
            if errno == EINTR { continue }
            return written
        }
        if pr == 0 { continue }
        if pollfds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            return written
        }
    }
    return written
}

@discardableResult
public func writePtyBlocking(fd: Int32, _ bytes: [UInt8]) -> Int {
    bytes.withUnsafeBufferPointer { buf in
        guard let p = buf.baseAddress else { return 0 }
        return writePtyBlocking(fd: fd, bytes: p, len: buf.count)
    }
}
