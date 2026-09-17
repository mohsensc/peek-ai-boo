import AppKit
import PeekCore
import SwiftUI

/// The pill: pure black, fused to the notch, no outline or border. The
/// ghosts are the only personality — no material here at all, so it reads
/// as part of the camera housing rather than a floating control.
struct PillView: View {
    var app: AppModel
    let notchWidth: CGFloat

    var body: some View {
        let _ = app.stillTick   // read so a still-check nudge forces a render
        TimelineView(.animation(minimumInterval: 0.1, paused: !anyMoving)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
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
        .contentShape(Rectangle())
        .onTapGesture { app.isOpen.toggle() }
        .contextMenu { menu }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var anyMoving: Bool {
        let now = nowMs()
        return app.store.sessions.values.contains { $0.isMoving(nowMs: now) }
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

/// The open island: a Liquid Glass panel a small gap below the pill (its
/// own window — see GlassPanel). One GlassGroup so the panel, its cards and
/// its rows sample and morph together instead of drawing isolated blurs.
/// Regular glass, concentric corners, system type: nothing in here is
/// custom chrome, just a grouped card, capsules and rows like any other
/// Tahoe popover.
struct PanelView: View {
    var app: AppModel

    var body: some View {
        GlassGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(app.features.enumerated()), id: \.offset) { _, feature in
                    feature.topRows(app: app)
                }
                if hasTopRows && !app.store.sessions.isEmpty {
                    Divider().opacity(0.5)
                }
                ForEach(app.store.ordered) { session in
                    SessionRow(session: session) { app.open(session) }
                }
                if app.store.sessions.isEmpty {
                    Text("no sessions yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .glassSurface(cornerRadius: GlassPanel.cornerRadius)
        .containerShape(RoundedRectangle(cornerRadius: GlassPanel.cornerRadius, style: .continuous))
    }

    private var hasTopRows: Bool {
        app.features.contains { $0.topRows(app: app) != nil }
    }
}
