import AppKit
import PeekCore
import SwiftUI

/// How wave-2 features plug into the app. Every hook has a do-nothing
/// default, so a feature only writes what it uses.
@MainActor
protocol Feature: AnyObject {
    /// Before NSApplication starts. Return an exit code to quit instead.
    func run(arguments: [String]) -> Int32?
    /// events.sock is bound and the panel is up.
    func start(app: AppModel)
    /// Every event, after the store applied it. Includes decide lines that
    /// a feature passed to app.ingest, and synthesized SessionEnds.
    func observe(_ event: Event, app: AppModel)
    /// Rows above the session list while the island is open.
    func topRows(app: AppModel) -> AnyView?
    /// Vertical points `topRows` will occupy, for sizing the panel's frame.
    /// SwiftUI's own fitting size fights NotchPanel's explicit setFrame
    /// calls (see the comment there), so the panel asks instead of measuring.
    func topRowsHeight(app: AppModel) -> CGFloat
    /// A session row was clicked. Return true if this feature handled it.
    func open(_ session: Session, app: AppModel) -> Bool
    /// Extra items for the island's right-click menu.
    func menuItems(app: AppModel) -> [NSMenuItem]
    /// A section to add to the settings window, if this feature has one.
    func settingsSections(app: AppModel) -> AnyView?
}

@MainActor
extension Feature {
    func run(arguments: [String]) -> Int32? { nil }
    func start(app: AppModel) {}
    func observe(_ event: Event, app: AppModel) {}
    func topRows(app: AppModel) -> AnyView? { nil }
    func topRowsHeight(app: AppModel) -> CGFloat { 0 }
    func open(_ session: Session, app: AppModel) -> Bool { false }
    func menuItems(app: AppModel) -> [NSMenuItem] { [] }
    func settingsSections(app: AppModel) -> AnyView? { nil }
}
