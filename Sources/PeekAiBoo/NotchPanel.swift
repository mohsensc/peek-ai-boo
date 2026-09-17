import AppKit
import PeekCore
import SwiftUI

/// Borderless, nonactivating, floats above the menu bar (`.statusBar` beats
/// the menu bar's own level). Fused to the notch: pure black, no material,
/// sized to exactly the pill — it never resizes, not even for a ping. It
/// owns the two things that drop below it: the persistent ping stack, and
/// (once clicked) the full glass panel. Only one of those is ever visible at
/// once, so the gap between whichever is showing and the pill is always
/// real desktop with no window in it — clicks there just fall through.
final class NotchPanel: NSPanel {
    private let app: AppModel
    private let geometry: NotchGeometry
    private let glass: GlassPanel
    private let pingStack: PingStackPanel
    private var outsideClickMonitor: Any?

    init(app: AppModel) {
        self.app = app
        self.geometry = NotchGeometry.current()
        self.glass = GlassPanel(app: app, geometry: geometry)
        self.pingStack = PingStackPanel(app: app, geometry: geometry)
        super.init(
            contentRect: NotchPanel.frame(geometry: geometry),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false

        let hosting = ClickCatchingHostingView(rootView: PillView(app: app, notchWidth: geometry.notch.width))
        // Left at its default, NSHostingView nudges the window toward
        // SwiftUI's own idea of a fitting size the moment content changes
        // (e.g. the empty-state text), fighting our explicit setFrame calls.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        contentView = hosting

        app.onChange = { [weak self] in self?.relayout() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
        installOutsideClickMonitor()
    }

    private func relayout() {
        setFrame(NotchPanel.frame(geometry: geometry), display: true)
        glass.relayout(open: app.isOpen, pillFrame: frame)
        // Hidden while the panel is open — that's the same slot below the
        // pill, and the panel already shows every pending prompt itself.
        pingStack.relayout(show: !app.isOpen, pillFrame: frame)
        if DebugCapture.printGeometry {
            DebugCapture.printFrame("PILL", self)
            DebugCapture.printFrame("PANEL", glass)
            DebugCapture.printFrame("PINGS", pingStack)
        }
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, self.app.isOpen else { return }
            let point = NSEvent.mouseLocation
            if !self.frame.contains(point) && !self.glass.frame.contains(point) {
                DispatchQueue.main.async { self.app.isOpen = false }
            }
        }
    }

    static func frame(geometry: NotchGeometry) -> NSRect {
        let width = geometry.notch.width + 220
        let height: CGFloat = 36
        return NSRect(
            x: geometry.notch.midX - width / 2,
            y: geometry.notch.maxY - height,
            width: width,
            height: height
        )
    }
}

/// The Liquid Glass popover that drops below the pill when the island is
/// open. Its own borderless panel rather than the pill's content, so it can
/// be sized to exactly its rounded shape: the space around it, including
/// the gap up to the pill, is real desktop that nothing is covering.
final class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 30
    static let gap: CGFloat = 6

    private let app: AppModel
    private let geometry: NotchGeometry
    private var isEditingText = false

    init(app: AppModel, geometry: NotchGeometry) {
        self.app = app
        self.geometry = geometry
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let hosting = ClickCatchingHostingView(rootView: PanelView(app: app))
        hosting.cornerRadius = Self.cornerRadius
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        app.onPanelEditingChanged = { [weak self] editing in self?.setEditingText(editing) }
    }

    override var canBecomeKey: Bool { isEditingText }
    override var canBecomeMain: Bool { false }

    /// Same nonactivating-key dance as the pill used to do for itself: the
    /// Other field needs a real first responder, but grabbing key status
    /// shouldn't steal activation from whatever terminal was frontmost.
    private func setEditingText(_ editing: Bool) {
        if editing {
            isEditingText = true
            makeKey()
        } else {
            makeFirstResponder(nil)
            isEditingText = false
            resignKey()
        }
    }

    /// Ordered out (not just resized to zero) when closed, so it never
    /// eats a click over its old spot.
    func relayout(open: Bool, pillFrame: NSRect) {
        guard open else {
            orderOut(nil)
            return
        }
        let topRowsHeight = app.features.reduce(CGFloat(0)) { $0 + $1.topRowsHeight(app: app) }
        let rows = app.store.ordered.count
        let width = max(geometry.notch.width + 260, 320)
        let height = 40 + CGFloat(max(rows, 1)) * 34 + topRowsHeight
        let originX = geometry.notch.midX - width / 2
        let originY = pillFrame.minY - Self.gap - height
        setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        orderFrontRegardless()
    }
}

/// The stack of persistent ping capsules that springs down from the pill —
/// one small gap below it, centered under the notch. One window (not one
/// per capsule) so a capsule morphing into its card can sample and morph
/// within a single GlassEffectContainer (see GlassCompat.GlassGroup); a
/// MultiRegionHostingView gives each row its own hit-test rect instead of
/// treating the whole window as one shape, so the gaps between capsules —
/// and anything below the last one — stay real desktop.
final class PingStackPanel: NSPanel {
    static let width: CGFloat = 340
    static let gap: CGFloat = 6   // pill -> first capsule

    private let app: AppModel
    private let geometry: NotchGeometry
    private let hosting: MultiRegionHostingView<PingStackView>
    private var isEditingText = false

    init(app: AppModel, geometry: NotchGeometry) {
        self.app = app
        self.geometry = geometry
        hosting = MultiRegionHostingView(rootView: PingStackView(app: app))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        app.onPingEditingChanged = { [weak self] editing in self?.setEditingText(editing) }
    }

    override var canBecomeKey: Bool { isEditingText }
    override var canBecomeMain: Bool { false }

    private func setEditingText(_ editing: Bool) {
        if editing {
            isEditingText = true
            makeKey()
        } else {
            makeFirstResponder(nil)
            isEditingText = false
            resignKey()
        }
    }

    /// `show` is false while the full panel is open, or once there's
    /// nothing pending — ordered out rather than resized to zero, same
    /// reasoning as GlassPanel.
    func relayout(show: Bool, pillFrame: NSRect) {
        guard show, !app.pings.isEmpty else {
            orderOut(nil)
            return
        }
        let items = app.pings.map { PingStackLayout.Item(id: $0.id, ts: $0.ts, isDone: $0.isDone) }
        let screenHeight = NotchGeometry.builtIn().visibleFrame.height
        let heights = Dictionary(uniqueKeysWithValues: app.pings.map {
            ($0.id, PingRowMetrics.height(for: $0, app: app, screenHeight: screenHeight))
        })
        let result = PingStackLayout.layout(items, heights: heights)
        let originX = geometry.notch.midX - Self.width / 2
        let originY = pillFrame.minY - Self.gap - result.totalHeight
        setFrame(NSRect(x: originX, y: originY, width: Self.width, height: result.totalHeight), display: true)

        // PingStackLayout measures y top-down (row 0 at the top, like the
        // VStack SwiftUI draws), but this view keeps AppKit's normal
        // bottom-left bounds, so each row flips against the total height.
        hosting.regions = result.rows.map { row in
            // Expanded card: its own concentric radius. "+N more": still a
            // true capsule, so half its height. Everything else: a
            // collapsed row is a rounded rect now, not a capsule, so its
            // hit region has to use the same fixed radius SwiftUI draws it
            // with — see PingStackLayout.collapsedCornerRadius.
            let radius: CGFloat
            if row.id == app.expandedPingID {
                radius = PingCardView.cornerRadius
            } else if row.id == PingStackLayout.overflowID || row.isDone {
                radius = row.height / 2
            } else {
                radius = PingStackLayout.collapsedCornerRadius
            }
            let y = result.totalHeight - row.y - row.height
            return .init(rect: NSRect(x: 0, y: y, width: Self.width, height: row.height), cornerRadius: radius)
        }
        orderFrontRegardless()
        if DebugCapture.printGeometry { printHitTestReport() }
    }

    /// `--print-geometry` only: hitTest at each region's center (a click
    /// there must reach the capsule) and at the midpoint of each gap plus
    /// just above the top row (a click there must fall through to the
    /// desktop). Exercises the actual AppKit hitTest chain — the same one a
    /// real click goes through — rather than re-deriving the geometry by
    /// hand and asserting against itself.
    private func printHitTestReport() {
        let regions = hosting.regions
        for (i, region) in regions.enumerated() {
            let hit = hosting.hitTest(NSPoint(x: region.rect.midX, y: region.rect.midY)) != nil
            print("HITTEST row\(i) \(hit ? "hit" : "MISS")")
        }
        // regions[i] sits above regions[i+1] on screen (result.rows is
        // top-down), which in AppKit's bottom-up frame means regions[i] has
        // the *higher* minY: the real gap is between that row's bottom edge
        // and the next row's top edge.
        for i in 0..<max(0, regions.count - 1) {
            let gapY = (regions[i].rect.minY + regions[i + 1].rect.maxY) / 2
            let hit = hosting.hitTest(NSPoint(x: regions[i].rect.midX, y: gapY)) != nil
            print("HITTEST gap\(i) \(hit ? "HIT (should fall through)" : "miss")")
        }
        // A point well inside the rounded corner actually drawn (30% of the
        // radius in from each edge) has to hit — the corner-narrowing math
        // only exists to reject the true rectangle's corners, not eat into
        // the shape itself. Catches a region built with the wrong radius
        // (e.g. a collapsed row still using capsule math) that the
        // above/gap probes, aimed at row centers and gaps, wouldn't notice.
        if let first = regions.first, first.cornerRadius > 0 {
            let r = first.cornerRadius
            let inset = NSPoint(x: first.rect.minX + r * 0.3, y: first.rect.maxY - r * 0.3)
            let hit = hosting.hitTest(inset) != nil
            print("HITTEST corner-inset \(hit ? "hit" : "MISS (should hit)")")
        }
        if let first = regions.first {
            let above = NSPoint(x: first.rect.midX, y: first.rect.maxY + 20)
            let hit = hosting.hitTest(above) != nil
            print("HITTEST above-stack \(hit ? "HIT (should fall through)" : "miss")")
        }
        fflush(stdout)
    }
}

/// SwiftUI's gestures expect the usual key-window responder chain. A
/// nonactivating panel never gets that, so mouseDown is nudged along here —
/// except into a text field, which needs to keep its own first responder so
/// the caret and text selection work.
///
/// `cornerRadius` also narrows hit testing to the rounded rect actually
/// drawn: a borderless window is still a rectangle to the window server, so
/// without this its four corners would swallow clicks meant for whatever's
/// on the desktop behind them. 0 (the pill's default) skips the corner math
/// and just uses the plain rectangle, same as before.
final class ClickCatchingHostingView<Content: View>: NSHostingView<Content> {
    var cornerRadius: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), pointInRoundedRect(point, rect: bounds, cornerRadius: cornerRadius) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let hit = hitTest(convert(event.locationInWindow, from: nil))
        if !(hit is NSTextView) && !(hit is NSTextField) {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Same idea as ClickCatchingHostingView, but for a window drawing several
/// independent rounded shapes stacked with gaps (the ping stack) instead of
/// one shape filling the whole window: a click only lands if it's inside
/// one of `regions`, so the gaps between capsules fall through to the
/// desktop same as the space around them. Plain (unflipped) AppKit bounds,
/// same as every other view here — callers convert top-down row geometry
/// against the window's total height before handing it in.
final class MultiRegionHostingView<Content: View>: NSHostingView<Content> {
    struct Region {
        let rect: NSRect
        let cornerRadius: CGFloat
    }

    var regions: [Region] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard regions.contains(where: { pointInRoundedRect(point, rect: $0.rect, cornerRadius: $0.cornerRadius) }) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let hit = hitTest(convert(event.locationInWindow, from: nil))
        if !(hit is NSTextView) && !(hit is NSTextField) {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// A borderless window is still a rectangle to the window server; both
/// hosting views above use this to narrow hit-testing to the rounded shape
/// actually drawn, so a corner (or, for the ping stack, a gap between rows)
/// doesn't swallow a click meant for the desktop behind it.
private func pointInRoundedRect(_ point: NSPoint, rect: NSRect, cornerRadius: CGFloat) -> Bool {
    guard rect.contains(point) else { return false }
    let r = cornerRadius
    guard r > 0 else { return true }
    let inCornerBand = (point.x < rect.minX + r || point.x > rect.maxX - r)
        && (point.y < rect.minY + r || point.y > rect.maxY - r)
    guard inCornerBand else { return true }
    let corner = NSPoint(
        x: point.x < rect.midX ? rect.minX + r : rect.maxX - r,
        y: point.y < rect.midY ? rect.minY + r : rect.maxY - r
    )
    return hypot(point.x - corner.x, point.y - corner.y) <= r
}
