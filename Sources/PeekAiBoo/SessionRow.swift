import PeekCore
import SwiftUI

/// One line in the open island: project, agent, state ghost, current tool,
/// elapsed time while working, usage, and any note a feature left.
struct SessionRow: View {
    let session: Session
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                GhostView(client: session.id.client, pose: session.pose, phase: nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if let tool = session.tool {
                        Text(tool)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    if let note = session.note {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if session.state == .working, let start = session.promptStart {
                        // Scoped tick: only exists, and only runs, while
                        // this row is on screen and the session is working.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedText(from: start, to: context.date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if let usage = session.usage {
                        Text(usageText(usage))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func elapsedText(from start: Int64, to date: Date) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1000) - start
        let seconds = max(0, ms / 1000)
        return seconds < 60 ? "\(seconds)s" : String(format: "%dm%02ds", seconds / 60, seconds % 60)
    }

    private func usageText(_ usage: Usage) -> String {
        "\(compact(usage.total)) · \(compact(usage.context)) ctx"
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
    }
}
