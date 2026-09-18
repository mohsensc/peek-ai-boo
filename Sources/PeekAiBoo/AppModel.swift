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

    /// A done ping: never counts toward "+N more", never bumps an approval
    /// or question out of view, and fades on its own — see
    /// PingStackLayout.selectShown/doneVisible.
    var isDone: Bool {
        if case .info = kind { return true }
        return false
    }
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
    /// re-render at the moment an idle ghost, or a needsYou ghost's short
    /// wave, is due to go still, without a repeating timer driving that
    /// render.
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
    /// `--other-text`, paired with `--open-other`: types this into the
    /// field it just opened, for capturing what a typed Other answer looks
    /// like without a synthetic keystroke.
    @ObservationIgnored var debugOtherText: String?
    /// `--preselect-multi`: ticks the first two options of the first
    /// multiSelect question the moment its card is showing — screenshot
    /// scripts can't reach PingCardView's own @State picks any other way.
    @ObservationIgnored var debugPreselectMulti = false
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
    private var pruneTimer: DispatchSourceTimer?

    /// The per-pid `watch(pid:)` below (kqueue NOTE_EXIT via
    /// DispatchSourceProcess) is what normally notices a dead agent, but it
    /// only arms once some event has actually carried that pid -- a process
    /// that died in the gap before its first watch installed would leave a
    /// ghost behind forever. This is the safety net: a cheap `kill(pid, 0)`
    /// sweep, occasionally, not a hot poll.
    static let pruneInterval: TimeInterval = 30

    init(paths: Paths, home: String) {
        self.paths = paths
        self.home = home
        self.muted = UserDefaults.standard.bool(forKey: "muted")
        startPruneTimer()
    }

    /// Approval/question prompts plus unseen-done sessions, oldest first —
    /// minus any done ping past its fade window (PingStackLayout.
    /// doneVisible). PingStackPanel caps this at 3 visible plus a "+N more"
    /// capsule, and never lets a done ping count toward that cap or bump a
    /// blocking one out (PingStackLayout.selectShown).
    var pings: [PingEntry] {
        let now = nowMs()
        var items: [PingEntry] = (approvals?.pending ?? []).map {
            PingEntry(id: $0.id.uuidString, ts: $0.ts, key: $0.key, kind: .approval($0))
        }
        items += store.infoPings
            .filter { PingStackLayout.doneVisible(ts: $0.lastEvent, nowMs: now) }
            .map {
                PingEntry(id: "done:\($0.id.client.rawValue):\($0.id.agent)", ts: $0.lastEvent, key: $0.id, kind: .info($0))
            }
        return items.sorted { $0.ts < $1.ts }
    }

    func ingest(_ event: Event) {
        let effects = store.apply(event)
        apply(effects)
        for feature in features {
            feature.observe(event, app: self)
        }
        scheduleStillCheck()
        schedulePingFadeCheck()
        onChange?()
    }

    func beginPrompt(_ key: SessionKey, ts: Int64) {
        apply(store.beginPrompt(key, ts: ts))
        // beginPrompt is the one path into needsYou that doesn't run through
        // ingest() (ApprovalDesk.receive calls it after, not through, the
        // event pipeline), so without this the wave-end wakeup here never
        // gets armed and the ghost waves until some unrelated event forces
        // a render.
        scheduleStillCheck()
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

    /// One asyncAfter for the soonest ghost that should stop moving on its
    /// own — an idle ghost done bobbing, or a needsYou ghost past its short
    /// wave — so the island's TimelineView can pause instead of polling
    /// forever. Called from both ingest() and beginPrompt(), the two paths
    /// that can start a needsYou wave.
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

    private var pingFadeGeneration = 0

    /// One asyncAfter for the soonest done ping that's about to fall out of
    /// `pings` on its own — same one-shot-wakeup shape as scheduleStillCheck,
    /// just for PingStackLayout.doneVisible instead of ghost movement.
    /// stillTick's write both forces PingStackView to re-run `pings` (a pure
    /// function of wall-clock time Observation can't otherwise see) and, via
    /// onChange, gets PingStackPanel to actually shrink the window.
    private func schedulePingFadeCheck() {
        let now = nowMs()
        let deadlines = store.infoPings
            .map { $0.lastEvent + PingStackLayout.doneFadeMs }
            .filter { $0 > now }
        guard let at = deadlines.min() else { return }
        pingFadeGeneration += 1
        let generation = pingFadeGeneration
        let delaySeconds = max(0, Double(at - now)) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self, self.pingFadeGeneration == generation else { return }
            self.stillTick += 1
            self.onChange?()
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

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pruneInterval, repeating: Self.pruneInterval)
        timer.setEventHandler { [weak self] in self?.pruneDeadSessions() }
        timer.resume()
        pruneTimer = timer
    }

    private func pruneDeadSessions() {
        let now = nowMs()
        for session in store.sessions.values {
            guard let pid = session.term.pid, !processIsAlive(pid) else { continue }
            ingest(.sessionEnd(session.id, ts: now))
        }
    }
}
