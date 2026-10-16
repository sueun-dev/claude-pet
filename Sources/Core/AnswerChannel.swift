import Darwin
import Foundation

// Permission answers travel from the menu bar app to the waiting hook over a Unix socket,
// never through a file. The hook only accepts an answer from a process running this very
// executable, so an agent that can merely write files — or run curl, nc or python —
// cannot approve its own request.

/// Hook side: listens on prompts/<id>.sock until the menu bar app sends an answer.
final class AnswerListener {
    private let fd: Int32
    private let path: String

    init?(promptID: String) {
        let path = Paths.promptSocket(promptID).path
        guard var addr = socketAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        unlink(path)
        guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
        self.path = path
    }

    deinit {
        close(fd)
        unlink(path)
    }

    /// Waits up to `seconds` for one connection. Returns its answer if it came from this
    /// executable and was well formed (and acknowledges it); anything else is dropped.
    func nextAnswer(waitingAtMost seconds: Double) -> PermissionAnswer? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(seconds * 1000)) > 0 else { return nil }
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return nil }
        defer { close(conn) }
        // The sender stays connected until we acknowledge, so it is still alive to be checked.
        guard peerRunsThisExecutable(conn) else { return nil }
        setTimeout(conn, seconds: 1)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        while data.count < 1024 {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }
        guard let answer = (try? JSONDecoder().decode(PermissionReply.self, from: data))?.answer else { return nil }
        _ = write(conn, [acknowledgement], 1)
        return answer
    }
}

/// App side: delivers the user's answer to the hook waiting on that prompt. Blocks briefly
/// until the hook acknowledges; returns whether it accepted the answer.
@discardableResult
func sendAnswer(_ answer: PermissionAnswer, to promptID: String) -> Bool {
    guard var addr = socketAddress(Paths.promptSocket(promptID).path),
          let message = try? JSONEncoder().encode(PermissionReply(answer: answer)) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0,
          message.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == message.count else { return false }
    shutdown(fd, SHUT_WR)
    setTimeout(fd, seconds: 2)
    var reply: UInt8 = 0
    return read(fd, &reply, 1) == 1 && reply == acknowledgement
}

// MARK: - Socket plumbing

private let acknowledgement = UInt8(ascii: "1")

private func setTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

/// A Unix socket address for `path`, or nil if the path is too long for one.
private func socketAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else { return nil }
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
        path.withCString { src in _ = strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), src, capacity - 1) }
    }
    return addr
}

private func withSockaddr(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func peerRunsThisExecutable(_ conn: Int32) -> Bool {
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(conn, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
          let peer = executablePath(pid), let me = executablePath(getpid()) else { return false }
    return peer == me
}

private func executablePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)   // PROC_PIDPATHINFO_MAXSIZE
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}
