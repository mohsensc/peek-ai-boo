import PeekCore
import SwiftUI

/// Geometry shared between AppKit (sizing/positioning PingStackPanel and its
/// hit-test regions) and SwiftUI (drawing the same rows). Keeping both sides
/// reading the same numbers is what keeps a click and a pixel agreeing —
/// see PingStackPanel.relayout.
@MainActor
enum PingRowMetrics {
    static let optionsRowHeight: CGFloat = 30
    static let cardHeaderHeight: CGFloat = 40
    static let cardFooterChrome: CGFloat = 48   // Send button row + padding

    /// This entry's height right now: its card if it's the one expanded,
    /// else its plain collapsed-capsule height.
    static func height(for entry: PingEntry, app: AppModel, screenHeight: CGFloat) -> CGFloat {
        guard entry.id == app.expandedPingID,
              case .approval(let prompt) = entry.kind,
              let questions = prompt.questions
        else { return collapsedHeight(for: entry) }
        return cardHeight(for: prompt, questions: questions, app: app, screenHeight: screenHeight)
    }

    static func collapsedHeight(for entry: PingEntry) -> CGFloat {
        if case .approval(let prompt) = entry.kind, showsInlineOptions(prompt) {
            return PingStackLayout.collapsedHeight + optionsRowHeight
        }
        return PingStackLayout.collapsedHeight
    }

    static func showsInlineOptions(_ prompt: PendingPrompt) -> Bool {
        guard let questions = prompt.questions, questions.count == 1 else { return false }
        return questions[0].fitsInline
    }

    static func cardHeight(
        for prompt: PendingPrompt, questions: [Question], app: AppModel, screenHeight: CGFloat
    ) -> CGFloat {
        let openFields = app.approvals?.others[prompt.id]?.values.filter(\.isOpen).count ?? 0
        let footer = cardFooterChrome
            + CGFloat(questions.count) * (optionsRowHeight + 8)
            + CGFloat(openFields) * 30
        let content = contentHeight(for: questions)
        return PingCardHeight.layout(
            header: cardHeaderHeight, footer: footer, contentHeight: content, screenHeight: screenHeight
        ).total
    }

    /// A rough chars-per-line estimate at the card's fixed width, same
    /// "good enough" spirit as Approvals.topRowsHeight — real measurement
    /// isn't worth it when the ScrollView caps the actual drawing anyway.
    private static func contentHeight(for questions: [Question]) -> CGFloat {
        let charsPerLine: CGFloat = 38
        let lineHeight: CGFloat = 17
        return questions.reduce(CGFloat(0)) { total, q in
            let lines = max(1, (CGFloat(q.question.count) / charsPerLine).rounded(.up))
            return total + 14 /* header label */ + lines * lineHeight + 10 /* block spacing */
        }
    }
}

/// Jumps to the session's terminal the same way a session row does:
/// markSeen, then whichever feature handles it (TerminalJump, in practice).
@MainActor
enum PingActions {
    static func jump(_ key: SessionKey, _ app: AppModel) {
        guard let session = app.store.sessions[key] else { return }
        app.open(session)
    }
}

/// Ghost + project name, the left side of every capsule and card header.
/// Static (no phase): the pill already animates this session's ghost, and a
/// second animated copy here would undo the point of keeping pings cheap.
private struct PingSessionLabel: View {
    let key: SessionKey
    let app: AppModel

    var body: some View {
        HStack(spacing: 6) {
            GhostView(client: key.client, pose: app.store.sessions[key]?.pose ?? .idle, phase: nil)
            Text(app.store.sessions[key]?.project ?? "?")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }
}

/// The whole stack: up to 3 capsules (oldest/longest-blocked first) plus a
/// "+N more" capsule that opens the full panel. One GlassGroup so a capsule
/// morphing into its card samples together with its neighbors instead of
/// popping.
struct PingStackView: View {
    var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassGroup {
            VStack(spacing: PingStackLayout.gap) {
                ForEach(shown) { entry in
                    row(for: entry)
                        .frame(width: PingStackPanel.width, height: PingRowMetrics.height(for: entry, app: app, screenHeight: screenHeight))
                }
                if overflow > 0 {
                    OverflowCapsule(count: overflow) { app.isOpen = true }
                        .frame(width: PingStackPanel.width, height: PingStackLayout.collapsedHeight)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: shown.map(\.id))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: app.expandedPingID)
        }
    }

    private var shown: [PingEntry] { Array(app.pings.prefix(PingStackLayout.visibleLimit)) }
    private var overflow: Int { max(0, app.pings.count - shown.count) }
    private var screenHeight: CGFloat { NotchGeometry.builtIn().visibleFrame.height }

    @ViewBuilder
    private func row(for entry: PingEntry) -> some View {
        switch entry.kind {
        case .info(let session):
            InfoPingCapsule(entry: entry, session: session, app: app)
        case .approval(let prompt):
            if prompt.questions != nil {
                if entry.id == app.expandedPingID, let questions = prompt.questions {
                    PingCardView(entry: entry, prompt: prompt, questions: questions, app: app) {
                        app.expandedPingID = nil
                    }
                } else {
                    QuestionPingCapsule(entry: entry, prompt: prompt, app: app) {
                        app.expandedPingID = entry.id
                    }
                }
            } else {
                ApprovalPingCapsule(entry: entry, prompt: prompt, app: app)
            }
        }
    }
}

/// A plain permission prompt: project, command, terminal/deny/allow.
/// Never expands — there's nothing more to show than the one-liner already
/// on it.
struct ApprovalPingCapsule: View {
    let entry: PingEntry
    let prompt: PendingPrompt
    let app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            PingSessionLabel(key: entry.key, app: app)
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            GlassIconButton(systemName: "apple.terminal", help: "Terminal") {
                PingActions.jump(entry.key, app)
            }
            if prompt.hookGone {
                Text("terminal").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                GlassIconButton(systemName: "xmark", help: "Deny") { bindings.answer(.deny(message: nil)) }
                GlassIconButton(systemName: "checkmark", tinted: true, help: "Allow") { bindings.answer(.allow) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PingStackLayout.collapsedHeight)
        .glassCapsule()
    }

    private var bindings: PingBindings {
        app.approvals?.pingBindings(for: prompt, app: app)
            ?? PingBindings(other: { _ in OtherAnswer() }, setOther: { _, _ in }, answer: { _ in })
    }

    /// Bash gets the whole command rather than the 60-char summary, since
    /// that's what Allow runs — same as ApprovalRow.
    private var detail: String {
        if prompt.tool == "Bash", let command = prompt.toolInput?["command"]?.stringValue {
            return "Bash \(command)"
        }
        return prompt.summary
    }
}

/// A question, collapsed: header row plus (when it fits) the options inline
/// as small capsules a click answers directly. Tapping the body anywhere
/// else — or the whole row when it doesn't fit — expands to the card.
struct QuestionPingCapsule: View {
    let entry: PingEntry
    let prompt: PendingPrompt
    let app: AppModel
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PingSessionLabel(key: entry.key, app: app)
                Text(prompt.summary)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                GlassIconButton(systemName: "apple.terminal", help: "Terminal") {
                    PingActions.jump(entry.key, app)
                }
            }
            if let question = inlineQuestion {
                HStack(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                        GlassButton(action: { answer(question, i) }) {
                            Text(option.label).font(.system(size: 12))
                        }
                        .help(option.description)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .glassCapsule()
    }

    private var inlineQuestion: Question? {
        guard PingRowMetrics.showsInlineOptions(prompt) else { return nil }
        return prompt.questions?.first
    }

    private func answer(_ question: Question, _ i: Int) {
        let message = Question.answerMessage([question], answers: [[question.options[i].label]])
        app.approvals?.pingBindings(for: prompt, app: app).answer(.deny(message: message))
    }
}

/// A question, expanded: header (ghost, session, collapse, terminal), the
/// question(s) and their context scrolling in the middle, answers (and
/// Other) pinned at the bottom. Answering behaves exactly like the full
/// panel's ApprovalRow — same OtherAnswer state, same DecideReply — just
/// laid out for a narrow capsule morphing into a card instead of a wide row.
struct PingCardView: View {
    static let cornerRadius: CGFloat = 22

    let entry: PingEntry
    let prompt: PendingPrompt
    let questions: [Question]
    let app: AppModel
    let onCollapse: () -> Void

    @State private var picks: [Int: Set<Int>] = [:]
    @FocusState private var focusedOther: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                        context(i, q)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(width: PingStackPanel.width)
        .glassSurface(cornerRadius: Self.cornerRadius, concentric: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PingSessionLabel(key: entry.key, app: app)
            Spacer()
            GlassIconButton(systemName: "chevron.up", help: "Collapse", action: onCollapse)
            GlassIconButton(systemName: "apple.terminal", help: "Terminal") {
                PingActions.jump(entry.key, app)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PingRowMetrics.cardHeaderHeight)
    }

    private func context(_ i: Int, _ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q.header.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(q.question)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                optionsRow(i, q)
            }
            HStack {
                Spacer()
                GlassButton(prominent: true, action: send) { Text("Send") }
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.4)
            }
        }
        .padding(12)
    }

    private func optionsRow(_ i: Int, _ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { options(i, q) }
                VStack(alignment: .leading, spacing: 4) { options(i, q) }
            }
            if other(i).isOpen {
                otherField(i, q)
            }
        }
    }

    private func options(_ i: Int, _ q: Question) -> some View {
        Group {
            ForEach(Array(q.options.enumerated()), id: \.offset) { j, option in
                GlassButton(prominent: (picks[i] ?? []).contains(j), action: { toggle(i, j, q.multiSelect) }) {
                    Text(option.label)
                }
                .help(option.description)
            }
            otherPill(i)
        }
    }

    private func otherPill(_ i: Int) -> some View {
        let field = other(i)
        return GlassButton(prominent: field.committed, action: {
            if field.isOpen {
                cancelOther(i)
            } else if field.committed {
                setOther(i, OtherAnswer())
            } else {
                var opened = field
                opened.open()
                setOther(i, opened)
                focusedOther = i
            }
        }) {
            Text(field.committed ? field.text : "Other")
        }
    }

    private func otherField(_ i: Int, _ q: Question) -> some View {
        HStack(spacing: 6) {
            TextField("Other", text: Binding(
                get: { other(i).text },
                set: { var field = other(i); field.type($0); setOther(i, field) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule()
            .focused($focusedOther, equals: i)
            .onSubmit { commitOther(i, q) }
            .onKeyPress(.escape) { cancelOther(i); return .handled }
            .onAppear { focusedOther = i }

            Button(action: { commitOther(i, q) }) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canSubmitOther(i) ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitOther(i))
        }
    }

    private var bindings: PingBindings {
        app.approvals?.pingBindings(for: prompt, app: app)
            ?? PingBindings(other: { _ in OtherAnswer() }, setOther: { _, _ in }, answer: { _ in })
    }
    private func other(_ i: Int) -> OtherAnswer { bindings.other(i) }
    private func setOther(_ i: Int, _ value: OtherAnswer) { bindings.setOther(i, value) }

    private func canSubmitOther(_ i: Int) -> Bool { Question.cleanTypedAnswer(other(i).text) != nil }

    private func toggle(_ i: Int, _ j: Int, _ multi: Bool) {
        var picked = picks[i] ?? []
        if !multi {
            picked = [j]
            if other(i).committed { setOther(i, OtherAnswer()) }
        } else if picked.contains(j) {
            picked.remove(j)
        } else {
            picked.insert(j)
        }
        picks[i] = picked
    }

    private func commitOther(_ i: Int, _ q: Question) {
        var field = other(i)
        guard field.submit() != nil else { return }
        setOther(i, field)
        if !q.multiSelect { picks[i] = [] }
        focusedOther = nil
        if ready { send() }
    }

    private func cancelOther(_ i: Int) {
        var field = other(i)
        field.cancel()
        setOther(i, field)
        focusedOther = nil
    }

    private var ready: Bool {
        questions.indices.allSatisfy { !(picks[$0] ?? []).isEmpty || other($0).committed }
    }

    private func send() {
        let answers = questions.indices.map { i in
            questions[i].options.indices.filter { (picks[i] ?? []).contains($0) }.map { questions[i].options[$0].label }
        }
        var typed: [Int: String] = [:]
        for i in questions.indices where other(i).committed { typed[i] = other(i).text }
        bindings.answer(.deny(message: Question.answerMessage(questions, answers: answers, typed: typed)))
    }
}

/// A done session waiting to be acknowledged. Any click (other than the
/// terminal button) marks it seen and dismisses it — no answer to give,
/// just a nudge that's been read.
struct InfoPingCapsule: View {
    let entry: PingEntry
    let session: Session
    let app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            GhostView(client: entry.key.client, pose: session.pose, phase: nil)
            Text(session.project).font(.system(size: 13, weight: .semibold))
            Text("done")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            GlassIconButton(systemName: "apple.terminal", help: "Terminal") {
                PingActions.jump(entry.key, app)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PingStackLayout.collapsedHeight)
        .contentShape(Rectangle())
        .onTapGesture { app.dismissInfoPing(entry.key) }
        .glassCapsule()
    }
}

/// Beyond the 3 visible capsules: a click opens the full panel, same as
/// clicking the pill — that's where the rest of the queue already lives.
struct OverflowCapsule: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text("+\(count) more")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .frame(height: PingStackLayout.collapsedHeight)
        }
        .buttonStyle(.plain)
        .glassCapsule()
    }
}
