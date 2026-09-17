import AppKit
import PeekCore
import SwiftUI

/// Borderless, nonactivating, floats above the menu bar (`.statusBar` beats
/// the menu bar's own level). It's never key except while an Other answer
/// field is being edited, so mouseDown is forwarded by hand the rest of the
/// time instead of riding SwiftUI's normal key-window path.
final class NotchPanel: NSPanel {
    private let app: AppModel
    private let geometry: NotchGeometry
    private var outsideClickMonitor: Any?
    private var isEditingText = false

    init(app: AppModel) {
        self.app = app
        self.geometry = NotchGeometry.current()
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

        let hosting = ClickCatchingHostingView(
            rootView: IslandView(app: app, notchWidth: geometry.notch.width)
        )
        // Left at its default, NSHostingView nudges the window toward
        // SwiftUI's own idea of a fitting size the moment content changes
        // (e.g. the empty-state text), fighting our explicit setFrame calls.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        contentView = hosting

        app.onChange = { [weak self] in self?.relayout() }
        app.onEditingChanged = { [weak self] editing in self?.setEditingText(editing) }
    }

    override var canBecomeKey: Bool { isEditingText }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
        installOutsideClickMonitor()
    }

    /// A nonactivating panel can become key without stealing the owning
    /// app's activation, which is the whole point: typing in the Other
    /// field doesn't pull focus off whatever terminal was frontmost.
    private func setEditingText(_ editing: Bool) {
        if editing {
            isEditingText = true
            makeKey()
        } else {
            // Give up first responder before dropping key status, or the
            // text field can be left thinking it still owns the caret.
            makeFirstResponder(nil)
            isEditingText = false
            resignKey()
        }
    }

    private func relayout() {
        let state: LayoutState
        if app.isOpen {
            let topRowsHeight = app.features.reduce(CGFloat(0)) { $0 + $1.topRowsHeight(app: app) }
            state = .open(rows: app.store.ordered.count, topRowsHeight: topRowsHeight)
        } else if app.ping != nil {
            state = .pinging
        } else {
            state = .idleClosed
        }
        setFrame(NotchPanel.frame(for: state, geometry: geometry), display: true)
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, self.app.isOpen else { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.app.isOpen = false }
            }
        }
    }

    enum LayoutState {
        case idleClosed
        case pinging
        // topRowsHeight covers whatever features draw above the session
        // list (pending approvals, etc.) — rows alone undercounts the open
        // island whenever a feature has something to show there.
        case open(rows: Int, topRowsHeight: CGFloat)
    }

    static func frame(for state: LayoutState, geometry: NotchGeometry) -> NSRect {
        let width: CGFloat
        let height: CGFloat
        switch state {
        case .idleClosed:
            width = geometry.notch.width + 220
            height = 36
        case .pinging:
            width = max(geometry.notch.width + 260, 300)
            height = 36
        case .open(let rows, let topRowsHeight):
            width = max(geometry.notch.width + 260, 320)
            height = 48 + CGFloat(max(rows, 1)) * 30 + topRowsHeight
        }
        return NSRect(
            x: geometry.notch.midX - width / 2,
            y: geometry.notch.maxY - height,
            width: width,
            height: height
        )
    }
}

/// SwiftUI's gestures expect the usual key-window responder chain. A
/// nonactivating panel never gets that, so mouseDown is nudged along here —
/// except into the Other field, which needs to keep its own first
/// responder so the caret and text selection work.
final class ClickCatchingHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        let hit = hitTest(convert(event.locationInWindow, from: nil))
        if !(hit is NSTextView) && !(hit is NSTextField) {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}
