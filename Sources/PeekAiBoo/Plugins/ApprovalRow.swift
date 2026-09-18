import PeekCore
import SwiftUI

/// One pending prompt in the open island: Allow and Deny for a tool call,
/// or a picker per question for AskUserQuestion. Once the hook is gone the
/// buttons go, since nothing would read the answer.
struct ApprovalRow: View {
    let prompt: PendingPrompt
    let project: String
    /// "Other" state lives one level up (Approvals), since the panel's
    /// height needs to know when a field is open.
    let other: (Int) -> OtherAnswer
    let setOther: (Int, OtherAnswer) -> Void
    let answer: (DecideReply) -> Void

    /// Picked option indexes, per question index.
    @State private var picks: [Int: Set<Int>] = [:]
    @FocusState private var focusedOther: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(project)
                    .font(.system(size: 12, weight: .semibold))
                Text(prompt.questions == nil ? "needs approval" : "has a question")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
            }
            if let questions = prompt.questions {
                ForEach(Array(questions.enumerated()), id: \.offset) { i, question in
                    questionBlock(i, question)
                }
            } else {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            actions
        }
        .padding(10)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassSurface(cornerRadius: 22, concentric: true)
    }

    /// Bash gets the whole command rather than the 60-char summary, since
    /// that's what Allow runs.
    private var detail: String {
        if prompt.tool == "Bash", let command = prompt.toolInput?["command"]?.stringValue {
            return "Bash \(command)"
        }
        return prompt.summary
    }

    @ViewBuilder
    private var actions: some View {
        if prompt.hookGone {
            Text("answer in terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let questions = prompt.questions {
            HStack {
                Spacer()
                GlassButton(prominent: true, action: { send(questions) }) { Text("Send") }
                    .disabled(!ready(questions))
                    .opacity(ready(questions) ? 1 : 0.4)
            }
        } else {
            HStack(spacing: 8) {
                Spacer()
                GlassButton(action: { answer(.deny(message: nil)) }) { Text("Deny") }
                GlassButton(prominent: true, action: { answer(.allow) }) { Text("Allow") }
            }
        }
    }

    private func ready(_ questions: [Question]) -> Bool {
        questions.indices.allSatisfy { !(picks[$0] ?? []).isEmpty || other($0).committed }
    }

    private func questionBlock(_ i: Int, _ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.header.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(question.question)
                .font(.system(size: 13))
                .lineLimit(3)
            if !prompt.hookGone {
                // Short labels sit on one line; long ones stack.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { options(i, question) }
                    VStack(alignment: .leading, spacing: 4) { options(i, question) }
                }
                if other(i).isOpen {
                    otherField(i, question)
                }
            }
        }
    }

    private func options(_ i: Int, _ question: Question) -> some View {
        Group {
            ForEach(Array(question.options.enumerated()), id: \.offset) { j, option in
                GlassButton(prominent: (picks[i] ?? []).contains(j), action: {
                    toggle(question: i, option: j, multi: question.multiSelect)
                }) {
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
        // committed -- see docs/design.md.
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

    private func otherField(_ i: Int, _ question: Question) -> some View {
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
            .onSubmit { commitOther(i, question) }
            // Not onExitCommand: the field editor can claim Escape as
            // cancelOperation: before that ever fires. onKeyPress runs
            // ahead of the responder chain, so it always sees it.
            .onKeyPress(.escape) { cancelOther(i); return .handled }
            .onAppear { focusedOther = i }

            Button(action: { commitOther(i, question) }) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canSubmitOther(i) ? .primary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitOther(i))
        }
    }

    private func canSubmitOther(_ i: Int) -> Bool {
        Question.cleanTypedAnswer(other(i).text) != nil
    }

    private func toggle(question i: Int, option j: Int, multi: Bool) {
        var picked = picks[i] ?? []
        if !multi {
            picked = [j]
            // Radio semantics: picking a listed option drops a typed one.
            if other(i).committed { setOther(i, OtherAnswer()) }
        } else if picked.contains(j) {
            picked.remove(j)
        } else {
            picked.insert(j)
        }
        picks[i] = picked
    }

    private func commitOther(_ i: Int, _ question: Question) {
        var field = other(i)
        guard field.submit() != nil else { return }
        setOther(i, field)
        // Radio semantics: a typed answer replaces any picked option.
        if !question.multiSelect { picks[i] = [] }
        focusedOther = nil
        // One question, Enter answers it — no second click needed.
        if let questions = prompt.questions, ready(questions) { send(questions) }
    }

    private func cancelOther(_ i: Int) {
        var field = other(i)
        field.cancel()
        setOther(i, field)
        focusedOther = nil
    }

    private func send(_ questions: [Question]) {
        let answers = questions.enumerated().map { i, question in
            question.options.indices
                .filter { (picks[i] ?? []).contains($0) }
                .map { question.options[$0].label }
        }
        var typed: [Int: String] = [:]
        for i in questions.indices where other(i).committed {
            typed[i] = other(i).text
        }
        answer(.deny(message: Question.answerMessage(questions, answers: answers, typed: typed)))
    }
}
