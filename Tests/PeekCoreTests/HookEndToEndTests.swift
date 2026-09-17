import Foundation
import Testing
@testable import PeekCore

/// Runs the real C++ hook binary against a Swift LineServer, so the wire
/// format is checked end to end instead of just on the Swift side.
@Suite struct HookEndToEndTests {
    private static let hookBinaryPath: String = {
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        make.arguments = ["-C", "hook"]
        make.currentDirectoryURL = repoRoot
        try! make.run()
        make.waitUntilExit()
        precondition(make.terminationStatus == 0, "make -C hook failed")
        return repoRoot.appendingPathComponent("hook/.build/peekaboo-hook").path
    }()

    private func runHook(client: String, stdin: Data, env: [String: String]) -> (stdout: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.hookBinaryPath)
        process.arguments = ["--client", client]
        process.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        try! process.run()
        stdinPipe.fileHandleForWriting.write(stdin)
        try? stdinPipe.fileHandleForWriting.close()
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (out, process.terminationStatus)
    }

    @Test func preToolUseArrivesAsAParsedEvent() async throws {
        let dir = try shortTempDir()
        let received = Box<Data>()
        let server = try LineServer(
            path: dir.appendingPathComponent("events.sock").path, queue: DispatchQueue(label: "test")
        ) { data, connection in
            received.value = data
            connection.close()
        }
        defer { server.close() }

        let payload = """
            {"session_id":"sess-e2e","hook_event_name":"PreToolUse","tool_name":"Bash",\
            "tool_input":{"command":"npm test"},"cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl"}
            """
        let (_, status) = runHook(client: "claude", stdin: Data(payload.utf8), env: ["PEEKABOO_DIR": dir.path])
        #expect(status == 0)

        try await waitUntilE2E { received.value != nil }
        let event = try #require(Event.parse(received.value!))
        #expect(event.client == .claude)
        #expect(event.event == "PreToolUse")
        #expect(event.agent == "sess-e2e")
        #expect(event.tool == "Bash")
        #expect(event.cwd == "/tmp/proj")
        #expect(event.transcript == "/tmp/proj/t.jsonl")
        #expect(event.toolInput?["command"]?.stringValue == "npm test")
    }

    @Test func permissionRequestIsAllowedThroughDecideSocket() async throws {
        let dir = try shortTempDir()
        let holder = ConnectionBox()
        let server = try LineServer(
            path: dir.appendingPathComponent("decide.sock").path, queue: DispatchQueue(label: "test")
        ) { _, connection in
            holder.connection = connection
        }
        defer { server.close() }

        let payload = """
            {"session_id":"sess-e2e","hook_event_name":"PermissionRequest","tool_name":"Bash",\
            "tool_input":{"command":"npm test"}}
            """

        // The hook blocks on decide.sock until it gets a reply, so it has to
        // run off the test's own task while we wait for the connection and
        // hand-write the reply DecideReply expects, to check the wire format
        // directly rather than going through that type.
        let resultTask = Task.detached {
            self.runHook(client: "claude", stdin: Data(payload.utf8), env: ["PEEKABOO_DIR": dir.path])
        }

        try await waitUntilE2E { holder.connection != nil }
        holder.connection?.reply(Data(#"{"decision":"allow"}"#.utf8))

        let result = await resultTask.value
        #expect(result.status == 0)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        #expect(
            stdout
                == "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\","
                + "\"decision\":{\"behavior\":\"allow\"}}}\n")
    }
}

private func waitUntilE2E(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _connection: LineConnection?
    var connection: LineConnection? {
        get { lock.lock(); defer { lock.unlock() }; return _connection }
        set { lock.lock(); _connection = newValue; lock.unlock() }
    }
}
