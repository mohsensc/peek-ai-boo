import Foundation
import Testing
@testable import PeekCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite struct LineServerTests {
    @Test func lineArrivesWithOurOwnPeerPID() async throws {
        let dir = try shortTempDir()
        let path = dir.appendingPathComponent("events.sock").path
        let received = Received()
        let server = try LineServer(path: path, queue: DispatchQueue(label: "test")) { data, connection in
            received.set(data: data, pid: connection.peerPID)
        }
        defer { server.close() }

        // A full close() right after write() can race accept(): if the peer
        // is already gone, LOCAL_PEERPID reports ENOTCONN. A half-close
        // (what the real decide protocol uses) keeps the socket "connected"
        // for credential lookups while still letting the line be read.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try connectSocket(fd, path: path)
        _ = "hello\n".withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)
        defer { close(fd) }

        try await waitUntil { received.data != nil }

        #expect(received.data == Data("hello".utf8))
        #expect(received.pid == getpid())
    }

    @Test func socketModeIs0600() throws {
        let dir = try shortTempDir()
        let path = dir.appendingPathComponent("events.sock").path
        let server = try LineServer(path: path, queue: DispatchQueue(label: "test")) { _, _ in }
        defer { server.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test func longPathThrows() throws {
        let dir = try shortTempDir()
        let longName = String(repeating: "a", count: 100)
        let path = dir.appendingPathComponent(longName).path
        #expect(path.utf8.count > 103)
        var threw = false
        do {
            _ = try LineServer(path: path, queue: DispatchQueue(label: "test")) { _, _ in }
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test func isListeningTracksBindAndClose() throws {
        let dir = try shortTempDir()
        let path = dir.appendingPathComponent("events.sock").path
        #expect(LineServer.isListening(path) == false)
        let server = try LineServer(path: path, queue: DispatchQueue(label: "test")) { _, _ in }
        #expect(LineServer.isListening(path) == true)
        server.close()
        #expect(LineServer.isListening(path) == false)
    }

    @Test func emptyConnectionIsDropped() async throws {
        let dir = try shortTempDir()
        let path = dir.appendingPathComponent("events.sock").path
        let received = Received()
        let server = try LineServer(path: path, queue: DispatchQueue(label: "test")) { data, _ in
            received.set(data: data, pid: 0)
        }
        defer { server.close() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try connectSocket(fd, path: path)
        close(fd)   // closes without ever sending a line

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(received.data == nil)
    }

    @Test func replyReachesHalfClosedClient() async throws {
        let dir = try shortTempDir()
        let path = dir.appendingPathComponent("decide.sock").path
        let holder = ConnectionHolder()
        let server = try LineServer(path: path, queue: DispatchQueue(label: "test")) { _, connection in
            holder.connection = connection
        }
        defer { server.close() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try connectSocket(fd, path: path)
        _ = "line\n".withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)

        try await waitUntil { holder.connection != nil }
        holder.connection?.reply(Data("reply".utf8))

        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        close(fd)
        #expect(n > 0)
        #expect(String(bytes: buf[0..<max(n, 0)], encoding: .utf8) == "reply\n")
    }

    @Test func replyAfterClientGoneDoesNotCrash() async throws {
        let dir = try shortTempDir()
        let path = dir.appendingPathComponent("decide.sock").path
        let holder = ConnectionHolder()
        let server = try LineServer(path: path, queue: DispatchQueue(label: "test")) { _, connection in
            holder.connection = connection
        }
        defer { server.close() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try connectSocket(fd, path: path)
        _ = "line\n".withCString { write(fd, $0, strlen($0)) }
        close(fd)   // client is gone before the reply

        try await waitUntil { holder.connection != nil }
        holder.connection?.reply(Data("reply".utf8))   // must not raise SIGPIPE
    }
}

// Test-only helpers: a tiny synchronous unix-socket client, so these tests
// don't depend on the real (C++) hook binary.
private func connectSocket(_ fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
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
    guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func sendLine(path: String, _ line: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try connectSocket(fd, path: path)
    let withNewline = line + "\n"
    _ = withNewline.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _pid: pid_t = 0
    var data: Data? { lock.lock(); defer { lock.unlock() }; return _data }
    var pid: pid_t { lock.lock(); defer { lock.unlock() }; return _pid }
    func set(data: Data, pid: pid_t) {
        lock.lock(); _data = data; _pid = pid; lock.unlock()
    }
}

private final class ConnectionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _connection: LineConnection?
    var connection: LineConnection? {
        get { lock.lock(); defer { lock.unlock() }; return _connection }
        set { lock.lock(); _connection = newValue; lock.unlock() }
    }
}
