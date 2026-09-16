import AppKit
import SwiftUI

/// The settings window shell. One window for the whole app; whichever
/// feature needs it first creates it, and every feature's section shows up
/// here through `Feature.settingsSections`. Sounds is first to need one.
@MainActor
enum SettingsWindow {
    static func make(app: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
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

/// Every feature's settings section, in registration order, with a divider
/// between them.
private struct SettingsRootView: View {
    let app: AppModel

    var body: some View {
        let sections = app.features.compactMap { $0.settingsSections(app: app) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 { Divider() }
                    section
                }
            }
            .padding(16)
        }
        .frame(width: 340)
    }
}
