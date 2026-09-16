import Foundation
import PeekCore

/// Tails each session's transcript after every event and publishes a
/// running token total. Reads happen on one background serial queue so a
/// slow disk never blocks the event pipeline; at most one read is in
/// flight per session, with a later event marking it dirty instead of
/// piling up another read behind it.
@MainActor
final class UsageFeature: Feature {
    private struct Tracked: Sendable {
        var tail: TranscriptTail
        var reader: any UsageReader
    }

    private var tracked: [SessionKey: Tracked] = [:]
    private var pending: Set<SessionKey> = []
    private var dirty: Set<SessionKey> = []
    private let queue = DispatchQueue(label: "usage-feature")

    func observe(_ event: Event, app: AppModel) {
        let key = event.key

        if event.event == "SessionEnd" {
            tracked[key] = nil
            pending.remove(key)
            dirty.remove(key)
            return
        }

        guard let reader = Clients.usageReader(for: event.client),
              let path = reader.transcriptPath(for: event, home: app.home)
        else { return }

        if tracked[key] == nil {
            tracked[key] = Tracked(tail: TranscriptTail(path: path), reader: reader)
        }

        guard !pending.contains(key) else {
            dirty.insert(key)
            return
        }
        pending.insert(key)
        readOnce(key: key, app: app)
    }

    private func readOnce(key: SessionKey, app: AppModel) {
        guard let state = tracked[key] else {
            pending.remove(key)
            return
        }
        queue.async { [weak self] in
            var tail = state.tail
            var reader = state.reader
            if let result = try? tail.read() {
                if result.restarted, let fresh = Clients.usageReader(for: key.client) {
                    reader = fresh
                }
                for line in result.lines {
                    reader.feed(line)
                }
            }
            let usage = reader.usage
            DispatchQueue.main.async {
                self?.finishRead(key: key, tail: tail, reader: reader, usage: usage, app: app)
            }
        }
    }

    private func finishRead(key: SessionKey, tail: TranscriptTail, reader: any UsageReader, usage: Usage?, app: AppModel) {
        pending.remove(key)
        // The session ended while this read was in flight.
        guard tracked[key] != nil else {
            dirty.remove(key)
            return
        }
        tracked[key] = Tracked(tail: tail, reader: reader)
        if let usage {
            app.setUsage(key, usage)
        }
        if dirty.remove(key) != nil {
            pending.insert(key)
            readOnce(key: key, app: app)
        }
    }
}
