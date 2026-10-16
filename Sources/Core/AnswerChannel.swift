import Darwin
import Foundation

// Permission answers travel from the menu bar app to the waiting hook over a Unix socket,
// never through a file. An answer only counts when
//   1. the connecting process runs this very executable,
//   2. it then echoes a one-time challenge the hook sends only after that check — so a
//      process that connects first and turns into this executable afterwards (exec)
//      cannot answer: nothing left in it would read the challenge, and
//   3. it names exactly the request the hook is waiting on — the tool and command the
//      panel showed — so editing the session file the panel reads can't redirect a click.
// An agent that can write files or run network tools therefore can't approve its own request.

/// Hook side: listens on prompts/<id>.sock until the menu bar app answers that prompt.
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

    /// Waits up to `seconds` for one connection and returns its answer if it passes all
    /// three checks above (acknowledging it); anything else is dropped.
    func nextAnswer(to prompt: PermissionPrompt, waitingAtMost seconds: Double) -> PermissionAnswer? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(seconds * 1000)) > 0 else { return nil }
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return nil }
        defer { close(conn) }
        guard peerRunsThisExecutable(conn) else { return nil }
        let challenge = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        setTimeout(conn, seconds: 1)
        guard sendAll(conn, Data((challenge + "\n").utf8)),
              let reply = try? JSONDecoder().decode(PermissionReply.self, from: receiveAll(conn, upTo: 8192)),
              reply.challenge == challenge, reply.tool == prompt.tool, reply.detail == prompt.detail
        else { return nil }
        _ = sendAll(conn, Data([acknowledgement]))
        return reply.answer
    }
}

/// App side: answers `prompt` exactly as the panel showed it. Blocks briefly for the
/// hook's challenge and acknowledgement; returns whether the hook accepted the answer.
@discardableResult
func sendAnswer(_ answer: PermissionAnswer, to prompt: PermissionPrompt) -> Bool {
    guard var addr = socketAddress(Paths.promptSocket(prompt.id).path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { return false }
    setTimeout(fd, seconds: 2)
    guard let challenge = receiveLine(fd),
          let message = try? JSONEncoder().encode(PermissionReply(answer: answer, tool: prompt.tool,
                                                                   detail: prompt.detail, challenge: challenge)),
          sendAll(fd, message) else { return false }
    shutdown(fd, SHUT_WR)
    return receiveAll(fd, upTo: 1) == Data([acknowledgement])
}

// MARK: - Socket plumbing

private let acknowledgement = UInt8(ascii: "1")

private func setTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
}

/// Reads until the peer stops sending (or `limit` bytes, or the timeout).
private func receiveAll(_ fd: Int32, upTo limit: Int) -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 512)
    while data.count < limit {
        let n = read(fd, &buf, min(buf.count, limit - data.count))
        if n <= 0 { break }
        data.append(contentsOf: buf[..<n])
    }
    return data
}

/// Reads one short newline-terminated line, without the newline.
private func receiveLine(_ fd: Int32) -> String? {
    var line = Data()
    var byte: UInt8 = 0
    while line.count < 128, read(fd, &byte, 1) == 1 {
        if byte == UInt8(ascii: "\n") { return String(data: line, encoding: .utf8) }
        line.append(byte)
    }
    return nil
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
