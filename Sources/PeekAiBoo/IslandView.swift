import AppKit
import PeekCore
import SwiftUI

/// The pill: pure black, fused to the notch, no outline or border, always
/// notch-sized — it never widens, not even for a ping. The ghosts are the
/// only personality — no material here at all, so it reads as part of the
/// camera housing rather than a floating control. Pings live in their own
/// window below it; see PingStackView.
struct PillView: View {
    var app: AppModel
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            AnimatedGhostRow(app: app)
            Spacer(minLength: notchWidth)
            if app.store.waitingCount > 0 {
                Text("\(app.store.waitingCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture { app.isOpen.toggle() }
        .contextMenu { menu }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// The ghosts, alone: fixed-size sprites with no Spacer or other flexible
/// layout in the mix. Scoping the TimelineView to just this, on its own,
/// measured no CPU difference (~1.1-1.3% either way with a moving ghost) --
/// a SwiftUI/CoreAnimation commit at a fixed rate costs about the same
/// regardless of how little content is inside it. What actually fixed the
/// number is `interval(for:)` below: a flat 10fps for every pose was far
/// more than idle/working/done ever need, so most of a normal session's
/// life was waking the timer 3-7x more often than any sprite frame
/// actually changed. Kept the scoped layout anyway since it's the correct
/// shape (the pill's Spacer/count text have no reason to re-lay-out on
/// every animation tick), just not, by itself, the fix.
private struct AnimatedGhostRow: View {
    var app: AppModel

    var body: some View {
        let _ = app.stillTick   // read so a still-check nudge forces a render
        let fps = movingFPS
        TimelineView(.animation(minimumInterval: interval(for: fps), paused: fps.isEmpty)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            row(phase: phase)
        }
    }

    /// Live sessions get a ghost, needsYou first then working then most
    /// recent activity, capped at `PillGhostLayout.visibleSlots` -- the pill
    /// never resizes, so the rest fold into `overflow` instead of a ghost.
    /// Only the shown ones need to keep the timer awake: one hidden behind
    /// the "+K" badge isn't on screen, so its pose flipping wouldn't be seen
    /// anyway.
    private var selection: (shown: [Session], overflow: Int) {
        let sessions = app.store.sessions
        let items = sessions.values.map {
            PillGhostLayout.Item(id: ghostID($0), state: $0.state, lastEvent: $0.lastEvent)
        }
        let result = PillGhostLayout.selectShown(items)
        let byID = Dictionary(uniqueKeysWithValues: sessions.values.map { (ghostID($0), $0) })
        return (result.shown.compactMap { byID[$0] }, result.overflow)
    }

    /// Each currently-moving session's pose fps (ghost.json: idle 2, working
    /// 1.5, needs 4, done 1). Waking up at whatever the fastest one of those
    /// needs, instead of a flat 10fps for all of them, is most of the idle-
    /// CPU fix: a lone working ghost only flips 1.5 times a second, so it
    /// doesn't need a 10Hz timer either.
    private var movingFPS: [Double] {
        let now = nowMs()
        return selection.shown.compactMap { session in
            session.isMoving(nowMs: now) ? GhostView.fps(for: session.pose) : nil
        }
    }

    /// Same headroom the old flat 0.1s had over the fastest pose (needs, at
    /// 4fps): 2.5x oversampling so a flip never lands between two ticks.
    private func interval(for movingFPS: [Double]) -> Double {
        guard let maxFPS = movingFPS.max(), maxFPS > 0 else { return 1 }
        return max(1 / (maxFPS * 2.5), 0.05)
    }

    private func row(phase: Double) -> some View {
        let (shown, overflow) = selection
        return HStack(spacing: 4) {
            ForEach(shown) { session in
                GhostView(
                    client: session.id.client,
                    pose: session.pose,
                    phase: session.isMoving(nowMs: nowMs()) ? phase : nil
                )
            }
            if overflow > 0 {
                OverflowBadge(count: overflow) { app.isOpen = true }
            }
        }
    }
}

private func ghostID(_ session: Session) -> String {
    "\(session.id.client.rawValue):\(session.id.agent)"
}

/// The "+K" for live sessions past `PillGhostLayout.visibleSlots`: a real
/// circle so it reads as one more slot in the row, not a stray label.
/// Clicking it opens the full panel -- the same place clicking the pill
/// itself goes, just a more direct route when you already know there's more
/// waiting.
private struct OverflowBadge: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+\(count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .glassCircle()
        }
        .buttonStyle(.plain)
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
