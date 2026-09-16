import Foundation

/// Owns decide.sock. Holds each waiting hook's connection while its prompt
/// is pending. The one place that writes a reply is `answer`, and only for
/// a prompt the book hands back from `take`, so a prompt that's already
/// resolved or lost its hook never gets one.
///
/// Everything here runs on main, same as the app's event ingest, so a
/// click and a resolving event never interleave.
@MainActor
public final class ApprovalDesk {
    public private(set) var book = ApprovalBook()

    private let ingest: (Event) -> Void
    private let opened: (PendingPrompt) -> Void
    private let changed: () -> Void
    private var connections: [UUID: LineConnection] = [:]
    private var watches: [UUID: DispatchSourceProcess] = [:]
    private var server: LineServer?

    /// `ingest` sees every Claude PermissionRequest first, so its session
    /// exists by the time `opened` runs. `changed` runs after any change to
    /// `book.pending`, including a hook exiting on its own.
    public init(
        path: String,
        ingest: @escaping (Event) -> Void,
        opened: @escaping (PendingPrompt) -> Void,
        changed: @escaping () -> Void
    ) throws {
        self.ingest = ingest
        self.opened = opened
        self.changed = changed
        let queue = DispatchQueue(label: "com.mohsensc.peekaiboo.decide")
        server = try LineServer(path: path, queue: queue) { [weak self] data, connection in
            guard let event = Event.parse(data), event.client == .claude,
                  event.event == "PermissionRequest"
            else {
                connection.close()
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return connection.close() }
                    self.receive(event, connection)
                }
            }
        }
    }

    /// Every event the app applies. Resolved prompts get EOF, which the
    /// hook takes as "no decision", so the terminal's answer stands.
    public func observe(_ event: Event) -> [PendingPrompt] {
        let resolved = book.apply(event)
        guard !resolved.isEmpty else { return [] }
        for prompt in resolved {
            drop(prompt.id)?.close()
        }
        changed()
        return resolved
    }

    /// Writes the reply and hangs up. nil, with nothing written, when the
    /// prompt already resolved or its hook is gone.
    public func answer(_ id: UUID, _ reply: DecideReply) -> PendingPrompt? {
        guard let prompt = book.take(id) else { return nil }
        if let connection = drop(id) {
            // If the hook died a moment ago and the watch hasn't fired yet,
            // this lands on a dead socket. LineConnection ignores EPIPE.
            connection.reply(reply.line)
            connection.close()
        }
        changed()
        return prompt
    }

    /// Stops listening and hangs up on every waiting hook.
    public func close() {
        server?.close()
        server = nil
        for id in Array(connections.keys) {
            drop(id)?.close()
        }
    }

    private func receive(_ event: Event, _ connection: LineConnection) {
        ingest(event)
        guard let prompt = book.open(event) else {
            connection.close()
            return
        }
        connections[prompt.id] = connection
        opened(prompt)
        watchHook(prompt.id, pid: connection.peerPID)
        changed()
    }

    /// The hook half-closed after sending, so the socket goes quiet until we
    /// write. Its pid exiting is the only sign it's gone, whether it was
    /// killed or saw its agent exit.
    private func watchHook(_ id: UUID, pid: pid_t) {
        // 0 means it had already hung up by accept().
        guard pid > 0 else {
            hookExited(id)
            return
        }
        // An already-dead pid still fires: libdispatch fakes NOTE_EXIT when
        // registration fails with ESRCH.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hookExited(id)
                self.changed()
            }
        }
        watches[id] = source
        source.resume()
    }

    private func hookExited(_ id: UUID) {
        drop(id)?.close()
        book.hookGone(id)
    }

    private func drop(_ id: UUID) -> LineConnection? {
        watches.removeValue(forKey: id)?.cancel()
        return connections.removeValue(forKey: id)
    }
}
