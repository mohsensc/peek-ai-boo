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
    @ObservationIgnored private var desk: ApprovalDesk?

    func start(app: AppModel) {
        desk = try! ApprovalDesk(
            path: app.paths.decide,
            ingest: { [weak app] event in app?.ingest(event) },
            opened: { [weak app] prompt in
                app?.beginPrompt(prompt.key, reason: Self.reason(for: prompt))
            },
            changed: { [weak self] in
                guard let self, let desk = self.desk else { return }
                self.pending = desk.book.pending
            }
        )
    }

    func observe(_ event: Event, app: AppModel) {
        // beginPrompt is a counter, so one endPrompt per prompt, even when
        // a single Stop resolves several.
        for prompt in desk?.observe(event) ?? [] {
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
                        project: app.store.sessions[prompt.key]?.project ?? "?"
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
    func topRowsHeight(app: AppModel) -> CGFloat {
        guard !pending.isEmpty else { return 0 }
        let rows = pending.reduce(CGFloat(0)) { total, prompt in
            let chrome: CGFloat = 68   // header + actions row + card padding
            let body: CGFloat = prompt.questions.map { CGFloat($0.count) * 54 } ?? 44
            return total + chrome + body
        }
        return rows + CGFloat(pending.count - 1) * 6   // VStack spacing between rows
    }

    /// Rows capture only the id. The desk decides whether that prompt can
    /// still be answered, so a click on a row that's about to go is a no-op.
    private func answer(_ id: UUID, _ reply: DecideReply, app: AppModel?) {
        guard let prompt = desk?.answer(id, reply) else { return }
        app?.endPrompt(prompt.key)
    }

    private static func reason(for prompt: PendingPrompt) -> String {
        if let header = prompt.questions?.first?.header {
            return "has a question: \(header)"
        }
        return "needs approval: \(prompt.summary)"
    }
}
