import AppKit
import PeekCore
import SwiftUI

/// Borderless, nonactivating, floats above the menu bar (`.statusBar` beats
/// the menu bar's own level). Fused to the notch: pure black, no material,
/// sized to exactly the pill. It owns the glass panel that drops below it
/// when open, so the gap between them is real desktop with no window in
/// it — clicks there just fall through.
final class NotchPanel: NSPanel {
    private let app: AppModel
    private let geometry: NotchGeometry
    private let glass: GlassPanel
    private var outsideClickMonitor: Any?

    init(app: AppModel) {
        self.app = app
        self.geometry = NotchGeometry.current()
        self.glass = GlassPanel(app: app, geometry: geometry)
        super.init(
            contentRect: NotchPanel.frame(for: .idleClosed, geometry: geometry),
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
        let pillState: LayoutState = app.ping != nil ? .pinging : .idleClosed
        setFrame(NotchPanel.frame(for: pillState, geometry: geometry), display: true)
        glass.relayout(open: app.isOpen, pillFrame: frame)
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

    enum LayoutState {
        case idleClosed
        case pinging
    }

    static func frame(for state: LayoutState, geometry: NotchGeometry) -> NSRect {
        let width: CGFloat = state == .pinging
            ? max(geometry.notch.width + 260, 300)
            : geometry.notch.width + 220
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

        app.onEditingChanged = { [weak self] editing in self?.setEditingText(editing) }
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
        guard containsRounded(point) else { return nil }
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

    private func containsRounded(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let r = cornerRadius
        guard r > 0 else { return true }
        let inCornerBand = (point.x < bounds.minX + r || point.x > bounds.maxX - r)
            && (point.y < bounds.minY + r || point.y > bounds.maxY - r)
        guard inCornerBand else { return true }
        let corner = NSPoint(
            x: point.x < bounds.midX ? bounds.minX + r : bounds.maxX - r,
            y: point.y < bounds.midY ? bounds.minY + r : bounds.maxY - r
        )
        return hypot(point.x - corner.x, point.y - corner.y) <= r
    }
}
