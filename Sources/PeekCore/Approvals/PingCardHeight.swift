import CoreGraphics

/// Height math for a ping's expanded card: header and answer options are
/// fixed and always fully shown; only the question/context area between
/// them scrolls, and the whole card is capped at a fraction of the screen's
/// visible height so a long question can't push answers off screen.
public enum PingCardHeight {
    /// "A sensible fraction of the screen's visible height" — chosen so a
    /// card comfortably fits under the notch on a laptop display without
    /// reaching the dock.
    public static let maxScreenFraction: CGFloat = 0.6

    public struct Layout: Equatable {
        public let total: CGFloat
        public let scrollHeight: CGFloat
    }

    /// `contentHeight` is the context area's natural height if nothing
    /// capped it. header/footer never shrink — if the cap is somehow
    /// smaller than their sum (a tiny screen), they still win and the
    /// context area just goes to zero rather than clipping the footer.
    public static func layout(header: CGFloat, footer: CGFloat, contentHeight: CGFloat, screenHeight: CGFloat) -> Layout {
        let chrome = header + footer
        let cap = max(chrome, screenHeight * maxScreenFraction)
        let total = min(chrome + max(0, contentHeight), cap)
        let scrollHeight = max(0, total - chrome)
        return Layout(total: total, scrollHeight: scrollHeight)
    }
}
