import AppKit
import SwiftUI

/// The settings window shell. One window for the whole app; whichever
/// feature needs it first creates it, and every feature's section shows up
/// here through `Feature.settingsSections`. Sounds is first to need one.
@MainActor
enum SettingsWindow {
    static func make(app: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRootView(app: app))
        window.center()
        return window
    }
}

/// Every feature's settings, as sections of one grouped Form — the same
/// shape as System Settings on Tahoe. A feature contributes a `Section` (or
/// a group of them); this just lines them up.
private struct SettingsRootView: View {
    let app: AppModel

    var body: some View {
        Form {
            ForEach(Array(app.features.compactMap { $0.settingsSections(app: app) }.enumerated()), id: \.offset) { _, section in
                section
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
