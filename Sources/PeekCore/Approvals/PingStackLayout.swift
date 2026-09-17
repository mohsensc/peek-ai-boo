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

    public struct Item: Equatable {
        public let id: String
        public let ts: Int64
        public init(id: String, ts: Int64) {
            self.id = id
            self.ts = ts
        }
    }

    public struct Row: Equatable, Identifiable {
        public let id: String
        public let y: CGFloat
        public let height: CGFloat
    }

    public struct Result: Equatable {
        public let rows: [Row]
        public let overflow: Int
        public let totalHeight: CGFloat
    }

    /// Oldest (longest-blocked) first, capped at `visibleLimit`; the rest
    /// collapse into one "+N more" row that opens the full panel. `heights`
    /// gives each shown item's current height (a card taller than a plain
    /// capsule when it's the one expanded); anything missing falls back to
    /// `collapsedHeight`.
    public static func layout(_ items: [Item], heights: [String: CGFloat] = [:]) -> Result {
        let ordered = items.sorted { $0.ts < $1.ts }
        let shown = Array(ordered.prefix(visibleLimit))
        let overflow = max(0, ordered.count - shown.count)

        var y: CGFloat = 0
        var rows: [Row] = []
        for item in shown {
            let height = heights[item.id] ?? collapsedHeight
            rows.append(Row(id: item.id, y: y, height: height))
            y += height + gap
        }
        if overflow > 0 {
            rows.append(Row(id: overflowID, y: y, height: overflowHeight))
            y += overflowHeight + gap
        }
        let total = rows.isEmpty ? 0 : y - gap
        return Result(rows: rows, overflow: overflow, totalHeight: total)
    }
}
