import Foundation
import Observation
import PeekCore

struct Ping: Equatable {
    let key: SessionKey
    let text: String
}

/// The app's one piece of mutable state. SessionStore does the state-machine
/// work; this just wires its effects to sound, the ping banner and pid
/// watching, and gives features a place to read and act.
@MainActor
@Observable
final class AppModel {
    private(set) var store = SessionStore()
    var isOpen = false {
        didSet {
            guard isOpen, !oldValue else { return }
            store.markAllSeen()
        }
    }
    var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    private(set) var ping: Ping?
    /// No meaning of its own. IslandView reads it so a write forces a
    /// re-render at the moment an idle ghost is due to go still, without a
    /// repeating timer driving that render.
    private(set) var stillTick = 0

    let paths: Paths
    let home: String
    @ObservationIgnored var features: [any Feature] = []
    /// Called after anything that might change what the panel should show.
    /// The panel sets this instead of us importing AppKit here.
    @ObservationIgnored var onChange: (() -> Void)?

    private var pingGeneration = 0
    private var stillCheckGeneration = 0
    private var exitWatchers: [SessionKey: DispatchSourceProcess] = [:]

    init(paths: Paths, home: String) {
        self.paths = paths
        self.home = home
        self.muted = UserDefaults.standard.bool(forKey: "muted")
    }

    func ingest(_ event: Event) {
        let effects = store.apply(event)
        apply(effects)
        for feature in features {
            feature.observe(event, app: self)
        }
        scheduleStillCheck()
        onChange?()
    }

    func beginPrompt(_ key: SessionKey, reason: String) {
        apply(store.beginPrompt(key, reason: reason, ts: nowMs()))
        onChange?()
    }

    func endPrompt(_ key: SessionKey) {
        apply(store.endPrompt(key, ts: nowMs()))
        onChange?()
    }

    func setUsage(_ key: SessionKey, _ usage: Usage) {
        store.setUsage(key, usage)
        onChange?()
    }

    func setNote(_ key: SessionKey, _ note: String?) {
        store.setNote(key, note)
        onChange?()
    }

    /// markSeen, then features in order until one returns true.
    func open(_ session: Session) {
        store.markSeen(session.id)
        for feature in features {
            if feature.open(session, app: self) { break }
        }
        onChange?()
    }

    private func apply(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .chirp(_, let state):
                if !muted { Chirp.play(for: state) }
            case .ping(let key, let text):
                showPing(key: key, text: text)
            case .watchPID(let key, let pid):
                watch(pid: pid, key: key)
            case .removed(let key):
                exitWatchers[key]?.cancel()
                exitWatchers[key] = nil
            }
        }
    }

    /// Widens the island for ~4s. A stale generation means a newer ping
    /// already replaced this one, so the old timer is a no-op.
    private func showPing(key: SessionKey, text: String) {
        ping = Ping(key: key, text: text)
        pingGeneration += 1
        let generation = pingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.pingGeneration == generation else { return }
            self.ping = nil
            self.onChange?()
        }
    }

    /// One asyncAfter for the soonest idle ghost that should stop bobbing,
    /// so the island's TimelineView can pause instead of polling forever.
    private func scheduleStillCheck() {
        guard let at = store.nextStillAt(nowMs: nowMs()) else { return }
        stillCheckGeneration += 1
        let generation = stillCheckGeneration
        let delaySeconds = max(0, Double(at - nowMs())) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self, self.stillCheckGeneration == generation else { return }
            self.stillTick += 1
        }
    }

    private func watch(pid: Int32, key: SessionKey) {
        exitWatchers[key]?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.exitWatchers[key] = nil
            self?.ingest(.sessionEnd(key, ts: nowMs()))
        }
        source.resume()
        exitWatchers[key] = source
    }
}
