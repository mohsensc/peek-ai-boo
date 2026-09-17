import AppKit

/// Where the physical notch is, computed fresh from the screen. A pure
/// function of safeAreaInsets and the auxiliary areas macOS exposes around
/// the camera housing, so it's checked with a print instead of a unit test
/// (PeekCore, where the tests live, doesn't import AppKit).
struct NotchGeometry: Equatable {
    let notch: CGRect   // the cutout itself, in screen coordinates
    let hasNotch: Bool

    static func current() -> NotchGeometry {
        compute(screen: builtIn())
    }

    static func compute(screen: NSScreen) -> NotchGeometry {
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let rect = CGRect(
                x: left.maxX,
                y: screen.frame.maxY - inset,
                width: right.minX - left.maxX,
                height: inset
            )
            return NotchGeometry(notch: rect, hasNotch: true)
        }
        // No notch on this screen: fall back to a pill at top center.
        let width: CGFloat = 185
        let height: CGFloat = 32
        let rect = CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        return NotchGeometry(notch: rect, hasNotch: false)
    }

    /// The screen with a real notch, else NSScreen.main.
    static func builtIn() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
