import PeekCore
import SwiftUI

/// One pending prompt in the open island: Allow and Deny for a tool call,
/// or a picker per question for AskUserQuestion. Once the hook is gone the
/// buttons go, since nothing would read the answer.
struct ApprovalRow: View {
    let prompt: PendingPrompt
    let project: String
    let answer: (DecideReply) -> Void

    /// Picked option indexes, per question index.
    @State private var picks: [Int: Set<Int>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(project)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
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
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
            }
            actions
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
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
                .foregroundStyle(.white.opacity(0.6))
        } else if let questions = prompt.questions {
            let ready = questions.indices.allSatisfy { !(picks[$0] ?? []).isEmpty }
            HStack {
                Spacer()
                pill("Send", filled: true) { send(questions) }
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.4)
            }
        } else {
            HStack(spacing: 8) {
                Spacer()
                pill("Deny", filled: false) { answer(.deny(message: nil)) }
                pill("Allow", filled: true) { answer(.allow) }
            }
        }
    }

    private func questionBlock(_ i: Int, _ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.header.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(question.question)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(3)
            if !prompt.hookGone {
                // Short labels sit on one line; long ones stack.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { options(i, question) }
                    VStack(alignment: .leading, spacing: 4) { options(i, question) }
                }
            }
        }
    }

    private func options(_ i: Int, _ question: Question) -> some View {
        ForEach(Array(question.options.enumerated()), id: \.offset) { j, option in
            pill(option.label, filled: (picks[i] ?? []).contains(j)) {
                toggle(question: i, option: j, multi: question.multiSelect)
            }
            .help(option.description)
        }
    }

    private func toggle(question i: Int, option j: Int, multi: Bool) {
        var picked = picks[i] ?? []
        if !multi {
            picked = [j]
        } else if picked.contains(j) {
            picked.remove(j)
        } else {
            picked.insert(j)
        }
        picks[i] = picked
    }

    private func send(_ questions: [Question]) {
        let answers = questions.enumerated().map { i, question in
            question.options.indices
                .filter { (picks[i] ?? []).contains($0) }
                .map { question.options[$0].label }
        }
        answer(.deny(message: Question.answerMessage(questions, answers: answers)))
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(filled ? Color.black : Color.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}
