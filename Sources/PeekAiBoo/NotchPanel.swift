import AppKit
import PeekCore
import SwiftUI

/// Borderless, nonactivating, floats above the menu bar (`.statusBar` beats
/// the menu bar's own level). It never becomes key, so mouseDown is
/// forwarded by hand instead of riding SwiftUI's normal key-window path.
final class NotchPanel: NSPanel {
    private let app: AppModel
    private let geometry: NotchGeometry
    private var outsideClickMonitor: Any?

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
        let state: LayoutState
        if app.isOpen {
            state = .open(app.store.ordered.count)
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
        case open(Int)
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
        case .open(let rows):
            width = max(geometry.notch.width + 260, 320)
            height = 48 + CGFloat(max(rows, 1)) * 30
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
/// nonactivating panel never gets that, so mouseDown is nudged along here.
final class ClickCatchingHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}
