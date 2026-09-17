import Foundation
import Observation
import PeekCore
import SwiftUI

/// Answers Claude's permission prompts and questions from the notch. The
/// socket, connections and races live in ApprovalDesk; this just wires it
/// to the app and draws the rows.
@MainActor
@Observable
final class Approvals: Feature {
    private(set) var pending: [PendingPrompt] = []
    /// Prompt id -> question index -> "Other" field state. Lifted out of
    /// the row (rather than @State there) because topRowsHeight needs to
    /// know when a field is open, and a plain view can't be asked that
    /// from outside.
    private(set) var others: [UUID: [Int: OtherAnswer]] = [:]
    @ObservationIgnored private var desk: ApprovalDesk?

    func start(app: AppModel) {
        desk = try! ApprovalDesk(
            path: app.paths.decide,
            ingest: { [weak app] event in app?.ingest(event) },
            opened: { [weak app] prompt in
                app?.beginPrompt(prompt.key)
            },
            changed: { [weak self, weak app] in
                guard let self, let desk = self.desk else { return }
                let newPending = desk.book.pending
                if let app {
                    // hookGone hides a row's Other field without an
                    // endPrompt to hang the cleanup on, so it's done here.
                    let previouslyGone = Set(self.pending.filter(\.hookGone).map(\.id))
                    for prompt in newPending where prompt.hookGone && !previouslyGone.contains(prompt.id) {
                        self.releaseOthers(prompt.id, app: app)
                    }
                    if app.debugOpenOtherOnQuestion {
                        self.openFirstOtherField(newPending, app: app)
                    }
                    if app.debugExpandFirstQuestion, app.expandedPingID == nil,
                       let firstQuestion = newPending.first(where: { $0.questions != nil }) {
                        app.expandedPingID = firstQuestion.id.uuidString
                    }
                }
                self.pending = newPending
                // `changed` is the one place guaranteed to run after
                // `pending` actually reflects the new state (opened() fires
                // before this on a brand new request — see ApprovalDesk.receive
                // — so a relayout triggered from there would still read the
                // old array). The ping stack reads `pending` imperatively
                // outside SwiftUI's own reactivity, so it needs this poke;
                // topRows gets it for free from Observation.
                app?.onChange?()
            }
        )
    }

    func observe(_ event: Event, app: AppModel) {
        // beginPrompt is a counter, so one endPrompt per prompt, even when
        // a single Stop resolves several.
        for prompt in desk?.observe(event) ?? [] {
            releaseOthers(prompt.id, app: app)
            app.endPrompt(prompt.key)
        }
    }

    func topRows(app: AppModel) -> AnyView? {
        guard !pending.isEmpty else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pending) { prompt in
                    ApprovalRow(
                        prompt: prompt,
                        project: app.store.sessions[prompt.key]?.project ?? "?",
                        other: { [weak self] i in self?.others[prompt.id]?[i] ?? OtherAnswer() },
                        setOther: { [weak self, weak app] i, value in
                            guard let self, let app else { return }
                            self.setOtherAnswer(prompt.id, i, value, app: app)
                        }
                    ) { [weak self, weak app] reply in
                        self?.answer(prompt.id, reply, app: app)
                    }
                }
            }
        )
    }

    /// A plain allow/deny row and a question row aren't the same height as
    /// each other or as a SessionRow, so the panel can't just count them.
    /// These are estimates (card chrome plus a line per question), not a
    /// pixel-exact measurement — good enough to stop rows getting clipped.
    /// Each open "Other" field adds one more line on top of that.
    func topRowsHeight(app: AppModel) -> CGFloat {
        guard !pending.isEmpty else { return 0 }
        let rows = pending.reduce(CGFloat(0)) { total, prompt in
            let chrome: CGFloat = 68   // header + actions row + card padding
            let body: CGFloat = prompt.questions.map { CGFloat($0.count) * 54 } ?? 44
            let openFields = others[prompt.id]?.values.filter(\.isOpen).count ?? 0
            return total + chrome + body + CGFloat(openFields) * 28
        }
        return rows + CGFloat(pending.count - 1) * 6   // VStack spacing between rows
    }

    /// The ping stack's capsules and cards need the same other/setOther/
    /// answer trio ApprovalRow gets from topRows, just addressed by prompt
    /// instead of built inline — PingStackView draws several kinds of ping,
    /// only one of which is an approval prompt.
    func pingBindings(for prompt: PendingPrompt, app: AppModel) -> PingBindings {
        PingBindings(
            other: { [weak self] i in self?.others[prompt.id]?[i] ?? OtherAnswer() },
            setOther: { [weak self, weak app] i, value in
                guard let self, let app else { return }
                self.setOtherAnswer(prompt.id, i, value, app: app)
            },
            answer: { [weak self, weak app] reply in
                guard let self, let app else { return }
                self.answer(prompt.id, reply, app: app)
            }
        )
    }

    /// Rows capture only the id. The desk decides whether that prompt can
    /// still be answered, so a click on a row that's about to go is a no-op.
    private func answer(_ id: UUID, _ reply: DecideReply, app: AppModel?) {
        guard let prompt = desk?.answer(id, reply), let app else { return }
        releaseOthers(id, app: app)
        app.endPrompt(prompt.key)
        if app.expandedPingID == id.uuidString { app.expandedPingID = nil }
    }

    /// Opening or closing a field changes the card's height, so this is
    /// the one place that also has to nudge the panel to relayout — pending
    /// changes already do that through beginPrompt/endPrompt.
    private func setOtherAnswer(_ id: UUID, _ i: Int, _ value: OtherAnswer, app: AppModel) {
        let was = others[id]?[i]?.isOpen ?? false
        others[id, default: [:]][i] = value
        let now = value.isOpen
        if now && !was { app.beginEditingText() }
        if was && !now { app.endEditingText() }
        if now != was { app.onChange?() }
    }

    /// Releases any open fields' editing credit and drops this prompt's
    /// Other state. Returns whether anything was actually open, so the
    /// hookGone path only pays for a relayout when the height could change.
    @discardableResult
    private func releaseOthers(_ id: UUID, app: AppModel) -> Bool {
        guard let fields = others.removeValue(forKey: id) else { return false }
        var released = false
        for field in fields.values where field.isOpen {
            app.endEditingText()
            released = true
        }
        return released
    }

    /// The island closed. ApprovalRow gets torn down and rebuilt fresh on
    /// reopen (its @State picks go with it the same way), so any Other
    /// field left open here would otherwise hold its editing credit and
    /// its `others` entry forever — the panel would stay keyable at the
    /// closed 36pt strip, and reopening would show a field the credit
    /// doesn't back anymore.
    func closed(app: AppModel) {
        for id in Array(others.keys) {
            releaseOthers(id, app: app)
        }
    }

    /// Same path a click on the Other pill takes, just triggered by a
    /// question showing up instead of a tap — see AppModel.debugOpenOtherOnQuestion.
    private func openFirstOtherField(_ pending: [PendingPrompt], app: AppModel) {
        for prompt in pending where prompt.questions != nil {
            guard others[prompt.id]?[0] == nil else { continue }
            var field = OtherAnswer()
            field.open()
            setOtherAnswer(prompt.id, 0, field, app: app)
        }
    }
}

/// What a ping capsule or card needs to answer its prompt, addressed by
/// question index for `other`/`setOther`. Mirrors the closures topRows
/// builds inline for ApprovalRow.
struct PingBindings {
    let other: (Int) -> OtherAnswer
    let setOther: (Int, OtherAnswer) -> Void
    let answer: (DecideReply) -> Void
}
