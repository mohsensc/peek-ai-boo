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
        else { return collapsedHeight(for: entry, app: app) }
        return cardHeight(for: prompt, questions: questions, app: app, screenHeight: screenHeight)
    }

    /// A done ping is its own, shorter, one-line shape; everything else is
    /// the normal two-line capsule, grown by a row when an inline
    /// two-option question's Other field is open (row 3 — see
    /// PingStackLayout.collapsedHeight(rowThree:), which is pure and
    /// carries the actual math).
    static func collapsedHeight(for entry: PingEntry, app: AppModel) -> CGFloat {
        if case .info = entry.kind { return PingStackLayout.doneHeight }
        return PingStackLayout.collapsedHeight(rowThree: showsOpenOtherRow(entry, app: app))
    }

    private static func showsOpenOtherRow(_ entry: PingEntry, app: AppModel) -> Bool {
        guard case .approval(let prompt) = entry.kind, showsInlineOptions(prompt) else { return false }
        return app.approvals?.others[prompt.id]?[0]?.isOpen ?? false
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
            + questions.reduce(CGFloat(0)) { $0 + optionsRowsHeight(for: $1) }
            + CGFloat(openFields) * 30
        let content = contentHeight(for: questions)
        return PingCardHeight.layout(
            header: cardHeaderHeight, footer: footer, contentHeight: content, screenHeight: screenHeight
        ).total
    }

    /// One question's pill row(s) in the card footer. `ViewThatFits` draws
    /// the options (plus Other) on one line when they fit the card's width,
    /// else falls back to stacking them — a 4-option-plus-Other question
    /// wraps to 5 tall pills, not one `optionsRowHeight` line, and the old
    /// flat estimate here clipped the card's own footer once questions with
    /// more than a couple of options started reaching the card instead of
    /// answering inline. Same rough chars-per-line spirit as contentHeight:
    /// not real measurement, just enough to stop it clipping.
    private static func optionsRowsHeight(for question: Question) -> CGFloat {
        let labels = question.options.map(\.label.count) + [5]   // + "Other"
        let chars = labels.reduce(0, +) + labels.count * 4   // rough per-pill padding
        guard chars > 40 else { return optionsRowHeight + 8 }
        let perPill: CGFloat = 34
        let spacing: CGFloat = 4
        let count = CGFloat(labels.count)
        return count * perPill + max(0, count - 1) * spacing + 8
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
        // A done ping's visibility is a pure function of wall-clock time
        // (PingStackLayout.doneVisible), which Observation can't track on
        // its own — stillTick's write at the fade deadline (AppModel.
        // schedulePingFadeCheck) is what forces this body to re-run and
        // drop it from `shown`.
        let _ = app.stillTick
        GlassGroup {
            VStack(spacing: PingStackLayout.gap) {
                ForEach(shown) { entry in
                    row(for: entry)
                        .frame(width: PingStackPanel.width, height: PingRowMetrics.height(for: entry, app: app, screenHeight: screenHeight))
                }
                if overflow > 0 {
                    OverflowCapsule(count: overflow) { app.isOpen = true }
                        .frame(width: PingStackPanel.width, height: PingStackLayout.overflowHeight)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: shown.map(\.id))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: app.expandedPingID)
        }
    }

    /// Same selection PingStackPanel.relayout uses, so SwiftUI never draws
    /// a different set of rows than AppKit sized a window for.
    private var selection: PingStackLayout.Selection {
        PingStackLayout.selectShown(app.pings.map {
            PingStackLayout.Item(id: $0.id, ts: $0.ts, isDone: $0.isDone)
        })
    }
    private var shown: [PingEntry] {
        let byID = Dictionary(uniqueKeysWithValues: app.pings.map { ($0.id, $0) })
        return selection.shown.compactMap { byID[$0.id] }
    }
    private var overflow: Int { selection.overflow }
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

/// Row 1's shell for every ping kind: the session name, then a "· kind
/// word" plus whatever buttons that kind gets. The name is the one side
/// that gives up space — no fixedSize, so it truncates — while the kind
/// cluster is wrapped in fixedSize so it always draws at its own natural
/// width, however wide the real glass buttons render. That split is the
/// whole truncation-priority fix: previously the kind word (lower
/// layoutPriority, no fixedSize) was the one that shrank, so "needs
/// approval" clipped to "needs appro…" next to a long session name instead
/// of the name giving way — see docs/design.md.
private struct PingRowOne<Trailing: View>: View {
    let project: String
    let kind: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 3) {
            Text(project)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Text("· \(kind)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                trailing()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
    }
}

/// A short-answer button living in row 1 itself (Dark/Light and friends):
/// same glass material as everywhere else, just sized down — row 1 has to
/// fit the terminal button and ✎ next to it too.
private struct PingRowOneOptionButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action) { Text(label).font(.system(size: 11, weight: .medium)) }
                .buttonStyle(.glass)
        } else {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Row 2 of a collapsed ping: the request or message, alone, spanning the
/// full text column. Middle-truncated (not tail) so a long shell command or
/// question still shows its end, not just where it starts.
private struct PingDetailLine: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The two-line shell every collapsed ping shares: a leading ghost centered
/// against both lines, then row 1 and row 2 stacked tight beside it. Kind-
/// specific content (buttons, detail text) is supplied by the caller; the
/// geometry itself comes from PingStackLayout so AppKit's window math and
/// this view never disagree about how tall a row actually is.
private struct PingRowShell<Row1: View, Row2: View>: View {
    let client: Client
    let pose: GhostPose
    @ViewBuilder let row1: () -> Row1
    @ViewBuilder let row2: () -> Row2

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            GhostView(client: client, pose: pose, phase: nil)
            VStack(alignment: .leading, spacing: PingStackLayout.rowSpacing) {
                row1().frame(height: PingStackLayout.rowOneHeight)
                row2().frame(height: PingStackLayout.rowTwoHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, PingStackLayout.rowOnePadding)
        .padding(.bottom, PingStackLayout.rowTwoPadding)
    }
}

/// A plain permission prompt: session/kind and buttons on row 1, the command
/// alone on row 2. Never expands — there's nothing more to show than what's
/// already on it.
struct ApprovalPingCapsule: View {
    let entry: PingEntry
    let prompt: PendingPrompt
    let app: AppModel

    var body: some View {
        PingRowShell(client: entry.key.client, pose: pose) {
            PingRowOne(project: project, kind: "needs approval") {
                GlassIconButton(systemName: "apple.terminal", help: "Terminal", size: 18) {
                    PingActions.jump(entry.key, app)
                }
                if prompt.hookGone {
                    Text("terminal").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    GlassIconButton(systemName: "xmark", help: "Deny", size: 18) { bindings.answer(.deny(message: nil)) }
                    GlassIconButton(systemName: "checkmark", tinted: true, help: "Allow", size: 18) { bindings.answer(.allow) }
                }
            }
        } row2: {
            PingDetailLine(text: detail, monospaced: true)
        }
        .frame(height: PingStackLayout.collapsedHeight)
        .glassSurface(cornerRadius: PingStackLayout.collapsedCornerRadius, concentric: true)
    }

    private var project: String { app.store.sessions[entry.key]?.project ?? "?" }
    private var pose: GhostPose { app.store.sessions[entry.key]?.pose ?? .idle }

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

/// A question, collapsed. Two shapes, chosen by `Question.fitsInline`:
///
/// - Two short single-select options: row 1 carries the terminal button,
///   both options as direct-answer buttons, and ✎ for Other in the slot an
///   approval would give deny/allow. Picking ✎ opens row 3, a typed answer
///   field pinned under row 2 — Esc or ✎ again collapses it.
/// - Everything else (3+ options, multiSelect, or options too long for row
///   1): row 1 just says "asks · N" plus a chevron that expands to the
///   full card, same as tapping the body anywhere else.
///
/// Row 2 is always the question text alone. Tapping the body — row 1 or
/// row 2, not row 3's field — always expands to the card, for either shape.
struct QuestionPingCapsule: View {
    let entry: PingEntry
    let prompt: PendingPrompt
    let app: AppModel
    let onExpand: () -> Void

    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PingRowShell(client: entry.key.client, pose: pose) {
                row1
            } row2: {
                PingDetailLine(text: prompt.summary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            if let question = inlineQuestion, other.isOpen {
                otherRow3(question)
            }
        }
        .frame(height: PingRowMetrics.collapsedHeight(for: entry, app: app))
        .glassSurface(cornerRadius: PingStackLayout.collapsedCornerRadius, concentric: true)
    }

    @ViewBuilder
    private var row1: some View {
        if let question = inlineQuestion {
            // Smaller icon buttons than the approval row (16 vs 18): this
            // row already has two more clickable things (both options) to
            // fit next to the terminal button and ✎.
            PingRowOne(project: project, kind: "asks") {
                GlassIconButton(systemName: "apple.terminal", help: "Terminal", size: 16) {
                    PingActions.jump(entry.key, app)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                    PingRowOneOptionButton(label: option.label) { answer(question, i) }
                }
                GlassIconButton(systemName: "pencil", tinted: otherActive, help: "Other", size: 16) {
                    toggleOther()
                }
            }
        } else {
            PingRowOne(project: project, kind: "asks · \(expandCount)") {
                GlassIconButton(systemName: "apple.terminal", help: "Terminal", size: 18) {
                    PingActions.jump(entry.key, app)
                }
                GlassIconButton(systemName: "chevron.down", help: "Expand", size: 18, action: onExpand)
            }
        }
    }

    private func otherRow3(_ question: Question) -> some View {
        HStack(spacing: 6) {
            TextField("type an answer…", text: Binding(
                get: { other.text },
                set: { var field = other; field.type($0); setOther(field) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule()
            .focused($otherFocused)
            .onSubmit { commitAndSend(question) }
            .onKeyPress(.escape) { cancelOther(); return .handled }
            .onAppear { otherFocused = true }

            Button(action: { commitAndSend(question) }) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canSubmitOther ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitOther)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, PingStackLayout.rowTwoPadding)
    }

    private var project: String { app.store.sessions[entry.key]?.project ?? "?" }
    private var pose: GhostPose { app.store.sessions[entry.key]?.pose ?? .idle }

    private var inlineQuestion: Question? {
        guard PingRowMetrics.showsInlineOptions(prompt) else { return nil }
        return prompt.questions?.first
    }

    private var expandCount: Int { Question.expandCount(prompt.questions ?? []) }

    private var bindings: PingBindings {
        app.approvals?.pingBindings(for: prompt, app: app)
            ?? PingBindings(other: { _ in OtherAnswer() }, setOther: { _, _ in }, answer: { _ in })
    }
    /// Always question index 0 — the inline shape only ever shows for a
    /// single question (PingRowMetrics.showsInlineOptions).
    private var other: OtherAnswer { bindings.other(0) }
    private func setOther(_ value: OtherAnswer) { bindings.setOther(0, value) }
    /// ✎ reads as selected from the click through typing until sent, not
    /// just once committed — see docs/design.md.
    private var otherActive: Bool { other.isOpen || other.committed }
    private var canSubmitOther: Bool { Question.cleanTypedAnswer(other.text) != nil }

    private func answer(_ question: Question, _ i: Int) {
        let message = Question.answerMessage([question], answers: [[question.options[i].label]])
        bindings.answer(.deny(message: message))
    }

    private func toggleOther() {
        var field = other
        if field.isOpen {
            field.cancel()
        } else if field.committed {
            field = OtherAnswer()
        } else {
            field.open()
        }
        setOther(field)
    }

    private func commitAndSend(_ question: Question) {
        var field = other
        guard field.submit() != nil else { return }
        setOther(field)
        otherFocused = false
        bindings.answer(.deny(message: Question.answerMessage([question], answers: [[]], typed: [0: field.text])))
    }

    private func cancelOther() {
        var field = other
        field.cancel()
        setOther(field)
        otherFocused = false
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
        .onAppear {
            // --preselect-multi: screenshot scripts can't click a card's own
            // @State options, so seed the first multiSelect question's first
            // two picks directly.
            guard app.debugPreselectMulti, picks.isEmpty,
                  let i = questions.firstIndex(where: \.multiSelect)
            else { return }
            picks[i] = Set(questions[i].options.indices.prefix(2))
        }
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
        // Green from the click through typing until sent, not just once
        // committed — see docs/design.md.
        return GlassButton(prominent: field.isOpen || field.committed, action: {
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

/// A done session waiting to be acknowledged: one line, no row 2, no
/// buttons — just the ghost and "session · done". The whole capsule is the
/// click target and jumps to the terminal (same as a session row), which is
/// what keeps "always be able to link to the terminal" true even with the
/// terminal button gone. It fades on its own — PingStackLayout.doneVisible
/// drops it from AppModel.pings once its session's `lastEvent` is old
/// enough — rather than waiting to be clicked; a click still marks it seen
/// (PingActions.jump -> AppModel.open -> markSeen) same as ever, it's just
/// no longer the only way it goes away.
struct InfoPingCapsule: View {
    let entry: PingEntry
    let session: Session
    let app: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            GhostView(client: entry.key.client, pose: session.pose, phase: nil)
            PingRowOne(project: session.project, kind: "done") { EmptyView() }
        }
        .padding(.horizontal, 12)
        .frame(height: PingStackLayout.doneHeight)
        .contentShape(Rectangle())
        .onTapGesture { PingActions.jump(entry.key, app) }
        .glassCapsule()
    }
}

/// Beyond the 3 visible capsules: a click opens the full panel, same as
/// clicking the pill — that's where the rest of the queue already lives.
/// Still a single line and a true capsule — no session, no request, nothing
/// the two-line row's ghost/buttons split would help with.
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
            .frame(height: PingStackLayout.overflowHeight)
        }
        .buttonStyle(.plain)
        .glassCapsule()
    }
}
