import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A unix-domain socket that reads one line per connection and hands it off.
/// Plain POSIX sockets plus DispatchSource: Network.framework needs an
/// entitlement CLT builds don't have.
public final class LineServer: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let queue: DispatchQueue
    private let onLine: @Sendable (Data, LineConnection) -> Void
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var closed = false

    /// Unlinks path, binds, chmod 0600, listens. Throws if the path is over
    /// 103 bytes or bind fails. onLine runs on `queue` once per connection
    /// with the first line (max 1 MiB, else the connection is dropped).
    /// Connections that close without a line are dropped quietly.
    public init(path: String, queue: DispatchQueue,
                onLine: @escaping @Sendable (Data, LineConnection) -> Void) throws {
        // Belt and suspenders with the per-socket SO_NOSIGPIPE below: a
        // write to a peer that's gone should return EPIPE, not kill us.
        signal(SIGPIPE, SIG_IGN)
        guard path.utf8.count <= 103 else {
            throw LineServerError.pathTooLong
        }
        self.path = path
        self.queue = queue
        self.onLine = onLine

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw LineServerError.socketFailed(errno) }

        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                path.withCString { strncpy(cptr, $0, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                bind(listenFD, sptr, size)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(listenFD)
            throw LineServerError.bindFailed(err)
        }

        chmod(path, 0o600)

        guard listen(listenFD, 16) == 0 else {
            let err = errno
            Darwin.close(listenFD)
            unlink(path)
            throw LineServerError.listenFailed(err)
        }

        fd = listenFD

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        src.setCancelHandler {
            Darwin.close(listenFD)
        }
        source = src
        src.resume()
    }

    private func acceptOne() {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }
        // LOCAL_PEERPID only answers while the socket is still connected —
        // a fast hook can close its end before we're done reading the line,
        // so the pid has to be grabbed right here, not later.
        let peerPID = Self.queryPeerPID(clientFD)
        readLine(clientFD: clientFD, peerPID: peerPID)
    }

    private static func queryPeerPID(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        return pid
    }

    private func readLine(clientFD: Int32, peerPID: pid_t) {
        // The blocking read loop lives on a global queue so one slow hook
        // can't stall accept() or another connection's callback. onLine
        // itself still runs on the caller's `queue`, per the contract.
        DispatchQueue.global().async { [onLine, queue] in
            var buffer = Data()
            var byte: UInt8 = 0
            var gotNewline = false
            var overLimit = false
            while true {
                let n = read(clientFD, &byte, 1)
                if n <= 0 { break }
                if byte == 0x0A { gotNewline = true; break }
                buffer.append(byte)
                if buffer.count > 1_048_576 {
                    overLimit = true
                    break
                }
            }
            guard gotNewline, !overLimit else {
                Darwin.close(clientFD)
                return
            }
            let connection = LineConnection(fd: clientFD, peerPID: peerPID)
            let line = buffer
            queue.async {
                onLine(line, connection)
            }
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        source?.cancel()
        unlink(path)
    }

    /// connect() succeeds.
    public static func isListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                path.withCString { strncpy(cptr, $0, 103) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                connect(fd, sptr, size)
            }
        }
        return result == 0
    }
}

enum LineServerError: Error {
    case pathTooLong
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

public final class LineConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var didClose = false

    /// getsockopt LOCAL_PEERPID, taken at accept() time (see queryPeerPID).
    public let peerPID: pid_t

    init(fd: Int32, peerPID: pid_t) {
        self.fd = fd
        self.peerPID = peerPID

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// appends "\n", ignores EPIPE and friends.
    public func reply(_ line: Data) {
        lock.lock()
        let target = fd
        lock.unlock()
        guard target >= 0 else { return }
        var data = line
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            let bytes = raw.bindMemory(to: UInt8.self)
            while offset < bytes.count {
                let n = write(target, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// idempotent.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !didClose else { return }
        didClose = true
        Darwin.close(fd)
    }
}
