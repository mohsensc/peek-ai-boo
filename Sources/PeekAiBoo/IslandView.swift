import AppKit
import PeekCore
import SwiftUI

/// The whole notch UI. One TimelineView drives every ghost; nothing else in
/// here ticks on its own.
struct IslandView: View {
    var app: AppModel
    let notchWidth: CGFloat

    var body: some View {
        let _ = app.stillTick   // read so a still-check nudge forces a render
        TimelineView(.animation(minimumInterval: 0.1, paused: !anyMoving)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Group {
                if app.isOpen {
                    openBody(phase: phase)
                } else {
                    closedBody(phase: phase)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.isOpen.toggle() }
        .contextMenu { menu }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: app.isOpen ? 16 : 12))
    }

    private var anyMoving: Bool {
        let now = nowMs()
        return app.store.sessions.values.contains { $0.isMoving(nowMs: now) }
    }

    private func closedBody(phase: Double) -> some View {
        HStack(spacing: 6) {
            ghostRow(phase: phase)
            Spacer(minLength: notchWidth)
            if let ping = app.ping {
                Text(ping.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else if app.store.waitingCount > 0 {
                Text("\(app.store.waitingCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private func ghostRow(phase: Double) -> some View {
        let ordered = app.store.ordered
        let shown = Array(ordered.prefix(8))
        let overflow = ordered.count - shown.count
        return HStack(spacing: 4) {
            ForEach(shown) { session in
                GhostView(
                    client: session.id.client,
                    pose: session.pose,
                    phase: session.isMoving(nowMs: nowMs()) ? phase : nil
                )
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func openBody(phase: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(app.features.enumerated()), id: \.offset) { _, feature in
                feature.topRows(app: app)
            }
            ForEach(app.store.ordered) { session in
                SessionRow(session: session) { app.open(session) }
            }
            if app.store.sessions.isEmpty {
                Text("no sessions yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var menu: some View {
        Button(app.muted ? "Unmute" : "Mute") { app.muted.toggle() }
        ForEach(Array(featureMenuItems.enumerated()), id: \.offset) { _, item in
            if item.isSeparatorItem {
                Divider()
            } else {
                Button(item.title) {
                    if let action = item.action {
                        _ = NSApp.sendAction(action, to: item.target, from: item)
                    }
                }
            }
        }
        Button("Quit") { NSApp.terminate(nil) }
    }

    private var featureMenuItems: [NSMenuItem] {
        app.features.flatMap { $0.menuItems(app: app) }
    }
}
