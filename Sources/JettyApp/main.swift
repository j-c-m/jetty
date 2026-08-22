import Darwin
import Jetty

/// Spawn stub: login shell at 105×35, copy PTY ↔ stdio. No window chrome.
@main
enum JettyMain {
    static func main() {
        guard let (fd, pid) = Pty.spawn() else {
            fputs("jetty: spawn failed\n", stderr)
            exit(1)
        }

        var stdinRaw = false
        var old = termios()
        if isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &old) == 0 {
            var raw = old
            cfmakeraw(&raw)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            stdinRaw = true
        }

        let sfl = fcntl(STDIN_FILENO, F_GETFL)
        if sfl >= 0 {
            _ = fcntl(STDIN_FILENO, F_SETFL, sfl | O_NONBLOCK)
        }

        var buf = [UInt8](repeating: 0, count: 4096)
        var fds = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
        ]
        loop: while true {
            let pr = poll(&fds, nfds_t(fds.count), -1)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                _ = writePtyBlocking(fd: fd, bytes: &buf, len: n)
            }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let n = read(fd, &buf, buf.count)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { raw -> Int in
                        write(STDOUT_FILENO, raw.baseAddress! + off, n - off)
                    }
                    if w < 0 {
                        if errno == EINTR { continue }
                        break loop
                    }
                    off += w
                }
            }
            if fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                break
            }
        }

        if stdinRaw {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &old)
        }
        close(fd)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}
