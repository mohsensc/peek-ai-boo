import Foundation
import Observation
import PeekCore

/// One capsule under the pill: a pending approval/question (persistent
/// until it resolves) or a done session waiting to be acknowledged
/// (persistent until clicked). Oldest first, same as the pill's own count.
enum PingKind {
    case approval(PendingPrompt)
    case info(Session)
}

struct PingEntry: Identifiable, Equatable {
    let id: String
    let ts: Int64
    let key: SessionKey
    let kind: PingKind

    static func == (lhs: PingEntry, rhs: PingEntry) -> Bool { lhs.id == rhs.id }
}

/// The app's one piece of mutable state. SessionStore does the state-machine
/// work; this just wires its effects to sound and pid watching, and gives
/// features a place to read and act.
@MainActor
@Observable
final class AppModel {
    private(set) var store = SessionStore()
    var isOpen = false {
        didSet {
            if isOpen && !oldValue {
                store.markAllSeen()
            }
            // Either surface tearing down (the full panel closing, or the
            // ping stack hiding because the panel just opened) drops any
            // Other field it was holding — see Feature.closed. Cheap to run
            // on both edges since it's a no-op when nothing was open.
            if isOpen != oldValue {
                for feature in features { feature.closed(app: self) }
                expandedPingID = nil
            }
            // The panel's size depends on isOpen, so every flip needs a
            // relayout, not just the one that also marks sessions seen.
            onChange?()
        }
    }
    var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    /// Which ping capsule (if any) is morphed open into its full card.
    /// Cleared whenever that prompt resolves or the panel takes over.
    var expandedPingID: String?
    /// No meaning of its own. IslandView reads it so a write forces a
    /// re-render at the moment an idle ghost is due to go still, without a
    /// repeating timer driving that render.
    private(set) var stillTick = 0

    let paths: Paths
    let home: String
    /// `--open-other`, for screenshot scripts that can't click the Other
    /// pill themselves: opens the first question's Other field the moment
    /// one shows up.
    @ObservationIgnored var debugOpenOtherOnQuestion = false
    /// `--expand-ping`: morphs the first question ping straight to its card,
    /// for capturing the scrolled/pinned-options state without a synthetic
    /// click.
    @ObservationIgnored var debugExpandFirstQuestion = false
    @ObservationIgnored var features: [any Feature] = []
    /// Set once, right after `features`, so ping rendering can reach
    /// Approvals' pending prompts without every feature needing a say in
    /// what a ping capsule looks like (only Approvals has any).
    @ObservationIgnored weak var approvals: Approvals?
    /// Called after anything that might change what the panel should show.
    /// The panel sets this instead of us importing AppKit here.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called when a text field starts or stops being edited (the "Other"
    /// answer field, so far) in the full panel, or in the ping stack's
    /// expanded card. Routed by `isOpen` since the two surfaces are never
    /// both on screen at once — see NotchPanel/PingStackPanel.
    @ObservationIgnored var onPanelEditingChanged: ((Bool) -> Void)?
    @ObservationIgnored var onPingEditingChanged: ((Bool) -> Void)?
    private var editingTextCount = 0

    private var stillCheckGeneration = 0
    private var exitWatchers: [SessionKey: DispatchSourceProcess] = [:]

    init(paths: Paths, home: String) {
        self.paths = paths
        self.home = home
        self.muted = UserDefaults.standard.bool(forKey: "muted")
    }

    /// Approval/question prompts plus unseen-done sessions, oldest first.
    /// PingStackPanel caps this at 3 visible plus a "+N more" capsule.
    var pings: [PingEntry] {
        var items: [PingEntry] = (approvals?.pending ?? []).map {
            PingEntry(id: $0.id.uuidString, ts: $0.ts, key: $0.key, kind: .approval($0))
        }
        items += store.infoPings.map {
            PingEntry(id: "done:\($0.id.client.rawValue):\($0.id.agent)", ts: $0.lastEvent, key: $0.id, kind: .info($0))
        }
        return items.sorted { $0.ts < $1.ts }
    }

    /// The info ping's own click: acknowledge and dismiss, same as opening
    /// the island would, but for just this one session.
    func dismissInfoPing(_ key: SessionKey) {
        store.markSeen(key)
        onChange?()
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

    func beginPrompt(_ key: SessionKey) {
        apply(store.beginPrompt(key))
        onChange?()
    }

    func endPrompt(_ key: SessionKey) {
        apply(store.endPrompt(key))
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

    /// Ref-counted since more than one field could plausibly be open at
    /// once (two pending questions); only the 0-to-1 and 1-to-0 edges are
    /// what a window cares about. Routed to whichever surface is currently
    /// showing question cards: the full panel while it's open, the ping
    /// stack's expanded card otherwise. They're never both visible at once
    /// (opening the panel collapses any expanded ping first), so there's
    /// never a question of which one a mid-flight edit belongs to.
    func beginEditingText() {
        editingTextCount += 1
        if editingTextCount == 1 { editingChanged(true) }
    }

    func endEditingText() {
        guard editingTextCount > 0 else { return }
        editingTextCount -= 1
        if editingTextCount == 0 { editingChanged(false) }
    }

    private func editingChanged(_ editing: Bool) {
        if isOpen { onPanelEditingChanged?(editing) } else { onPingEditingChanged?(editing) }
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
            case .watchPID(let key, let pid):
                watch(pid: pid, key: key)
            case .removed(let key):
                exitWatchers[key]?.cancel()
                exitWatchers[key] = nil
            }
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
