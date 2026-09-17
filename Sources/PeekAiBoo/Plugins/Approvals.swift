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
                app?.beginPrompt(prompt.key, reason: Self.reason(for: prompt))
            },
            changed: { [weak self, weak app] in
                guard let self, let desk = self.desk else { return }
                let newPending = desk.book.pending
                if let app {
                    // hookGone hides a row's Other field without an
                    // endPrompt to hang the cleanup on, so it's done here.
                    let previouslyGone = Set(self.pending.filter(\.hookGone).map(\.id))
                    var releasedAny = false
                    for prompt in newPending where prompt.hookGone && !previouslyGone.contains(prompt.id) {
                        if self.releaseOthers(prompt.id, app: app) { releasedAny = true }
                    }
                    if releasedAny { app.onChange?() }
                    if app.debugOpenOtherOnQuestion {
                        self.openFirstOtherField(newPending, app: app)
                    }
                }
                self.pending = newPending
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

    /// Rows capture only the id. The desk decides whether that prompt can
    /// still be answered, so a click on a row that's about to go is a no-op.
    private func answer(_ id: UUID, _ reply: DecideReply, app: AppModel?) {
        guard let prompt = desk?.answer(id, reply), let app else { return }
        releaseOthers(id, app: app)
        app.endPrompt(prompt.key)
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

    private static func reason(for prompt: PendingPrompt) -> String {
        if let header = prompt.questions?.first?.header {
            return "has a question: \(header)"
        }
        return "needs approval: \(prompt.summary)"
    }
}
