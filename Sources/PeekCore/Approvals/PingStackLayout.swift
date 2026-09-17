import CoreGraphics

/// Pure geometry for the stack of ping capsules under the pill: ordering,
/// the 3-visible/"+N more" cap, and where each row sits. AppKit sizes and
/// positions the ping window from this, and the view's hit-testing uses the
/// same rows, so the two can never disagree about where a capsule actually
/// is.
public enum PingStackLayout {
    public static let visibleLimit = 3
    public static let gap: CGFloat = 8
    /// The row `layout` appends when items are hidden behind "+N more".
    public static let overflowID = "__overflow__"
    /// "+N more" is still just one line of text — no session, no request to
    /// give room to — so it keeps the old one-line height rather than paying
    /// for the two-line capsule's row math below.
    public static let overflowHeight: CGFloat = 32
    /// Drawn corner radius for a collapsed row (a rounded rect now, not a
    /// true capsule — see PingRowMetrics/PingStackView). PingStackPanel's
    /// hit-test regions use this same number so a click near a corner and
    /// the pixel actually drawn there never disagree.
    public static let collapsedCornerRadius: CGFloat = 16

    // A collapsed ping is two tight lines: row 1 (ghost-height session name,
    // kind and buttons) and row 2 (the request/message, full width). Kept
    // here rather than only in SwiftUI so PeekAiBoo and this module's own
    // tests read the exact same numbers AppKit sizes the window from.
    public static let rowOnePadding: CGFloat = 6
    public static let rowOneHeight: CGFloat = 20
    public static let rowSpacing: CGFloat = 2
    public static let rowTwoHeight: CGFloat = 16
    public static let rowTwoPadding: CGFloat = 6
    public static let collapsedHeight: CGFloat =
        rowOnePadding + rowOneHeight + rowSpacing + rowTwoHeight + rowTwoPadding

    /// Row 3: the typed-answer field an inline two-option question grows
    /// when its ✎ is selected. Only that one case pays for it — the
    /// expanded card's own Other field is accounted for in its footer math
    /// instead (PingRowMetrics.cardHeight).
    public static let rowThreeHeight: CGFloat = 30

    /// `collapsedHeight`, plus row 3 when a question's typed-answer field
    /// is open. Pure so it's testable without an AppModel — PingRowMetrics
    /// (the app target) is the thin adapter that knows *when* that's true.
    public static func collapsedHeight(rowThree: Bool) -> CGFloat {
        rowThree ? collapsedHeight + rowThreeHeight : collapsedHeight
    }

    /// A done ping: one line, no buttons — see docs/design.md. Same
    /// footprint as "+N more" (both are true capsules with nothing but a
    /// line of text), kept as its own named constant since the two mean
    /// different things.
    public static let doneHeight: CGFloat = 32

    /// How long a done ping stays on screen, unclicked, before it fades on
    /// its own. Measured from the session's own `lastEvent`, not from
    /// whenever it happened to become visible — same "elapsed since ts" a
    /// needsYou wave already uses, so it's a pure function of time rather
    /// than something a view has to drive.
    public static let doneFadeMs: Int64 = 2_500

    public static func doneVisible(ts: Int64, nowMs: Int64) -> Bool {
        nowMs - ts < doneFadeMs
    }

    public struct Item: Equatable {
        public let id: String
        public let ts: Int64
        /// A done ping: never counts toward "+N more" and never bumps an
        /// approval or question out of its guaranteed slot — see
        /// `selectShown`.
        public let isDone: Bool
        public init(id: String, ts: Int64, isDone: Bool = false) {
            self.id = id
            self.ts = ts
            self.isDone = isDone
        }
    }

    public struct Row: Equatable, Identifiable {
        public let id: String
        public let y: CGFloat
        public let height: CGFloat
        public let isDone: Bool
    }

    public struct Result: Equatable {
        public let rows: [Row]
        public let overflow: Int
        public let totalHeight: CGFloat
    }

    public struct Selection: Equatable {
        public let shown: [Item]
        public let overflow: Int
    }

    /// Which items actually show, and how many are hidden behind "+N more"
    /// — the one place both AppKit's window sizing (`layout`) and SwiftUI's
    /// `PingStackView` decide this, so they can never disagree about which
    /// row is where. Approvals and questions ("blocking") always get up to
    /// `visibleLimit` slots regardless of how many done pings exist; done
    /// pings only fill whatever's left over, oldest first, and never count
    /// toward `overflow` — a burst of them can never push a real prompt out
    /// of view or make the stack claim there's "+N more" when there isn't.
    /// Shown order is blocking-then-done, not a merged re-sort by `ts`: a
    /// done ping fading in or out shouldn't shift an approval's position.
    public static func selectShown(_ items: [Item]) -> Selection {
        let blocking = items.filter { !$0.isDone }.sorted { $0.ts < $1.ts }
        let done = items.filter { $0.isDone }.sorted { $0.ts < $1.ts }
        let shownBlocking = Array(blocking.prefix(visibleLimit))
        let overflow = max(0, blocking.count - shownBlocking.count)
        let roomLeft = max(0, visibleLimit - shownBlocking.count)
        let shownDone = Array(done.prefix(roomLeft))
        return Selection(shown: shownBlocking + shownDone, overflow: overflow)
    }

    /// `heights` gives each shown item's current height (a card taller than
    /// a plain capsule when it's the one expanded); anything missing falls
    /// back to `collapsedHeight`.
    public static func layout(_ items: [Item], heights: [String: CGFloat] = [:]) -> Result {
        let selection = selectShown(items)

        var y: CGFloat = 0
        var rows: [Row] = []
        for item in selection.shown {
            let height = heights[item.id] ?? collapsedHeight
            rows.append(Row(id: item.id, y: y, height: height, isDone: item.isDone))
            y += height + gap
        }
        if selection.overflow > 0 {
            rows.append(Row(id: overflowID, y: y, height: overflowHeight, isDone: false))
            y += overflowHeight + gap
        }
        let total = rows.isEmpty ? 0 : y - gap
        return Result(rows: rows, overflow: selection.overflow, totalHeight: total)
    }
}

/// Row 1's fixed-width budget: how much of the panel's content width the
/// kind-word-and-buttons cluster is allowed to reserve before the session
/// name — the flexible side, the one that truncates — would have no room
/// left worth calling readable. SwiftUI still lays out the real glass
/// buttons at their own natural size, so this isn't a pixel-exact layout;
/// it exists to catch a future row-1 addition (a fourth button, a longer
/// kind word) that quietly eats the last of the name's space, the same way
/// a capture caught the last one (see docs/design.md).
public enum PingRowOneBudget {
    /// Mirrors PingStackPanel.width in the app target, duplicated here so
    /// PeekCoreTests can check this budget without depending on it.
    public static let panelWidth: CGFloat = 340
    /// PingRowShell's own horizontal padding, both sides.
    public static let horizontalInsets: CGFloat = 24
    /// The ghost column: a 13pt sprite plus the 8pt gap before the text.
    public static let ghostColumn: CGFloat = 21
    public static let contentWidth: CGFloat = panelWidth - horizontalInsets - ghostColumn

    /// One small glass button's worst-case rendered width. macOS 26 glass
    /// buttons draw wider than the frame they're asked for (confirmed
    /// against a real capture, not just the 18pt frame the button
    /// declares) — this is that slop, not the declared size.
    public static let iconButtonWidth: CGFloat = 30
    /// A text button (an inline option like "Dark" or "Light") — wider
    /// than an icon button since it has to fit a label, not just a glyph.
    public static let textButtonWidth: CGFloat = 46
    public static let buttonSpacing: CGFloat = 4
    /// Rough width per character of the "· kind" label at its 11pt font.
    public static let kindCharWidth: CGFloat = 6.5
    /// The shortest a name can draw and still read as a name, not just
    /// letters-then-ellipsis.
    public static let minimumNameWidth: CGFloat = 60

    /// True if `kindText` plus `iconButtons` icon buttons and `textButtons`
    /// text buttons still leaves at least `minimumNameWidth` for the name.
    public static func fits(kindText: String, iconButtons: Int, textButtons: Int = 0) -> Bool {
        let kindWidth = CGFloat(kindText.count) * kindCharWidth
        let buttons = CGFloat(iconButtons) * (iconButtonWidth + buttonSpacing)
            + CGFloat(textButtons) * (textButtonWidth + buttonSpacing)
        return kindWidth + buttons + minimumNameWidth <= contentWidth
    }
}
