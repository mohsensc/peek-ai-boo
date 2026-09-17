import CoreGraphics

/// Pure geometry for the stack of ping capsules under the pill: ordering,
/// the 3-visible/"+N more" cap, and where each row sits. AppKit sizes and
/// positions the ping window from this, and the view's hit-testing uses the
/// same rows, so the two can never disagree about where a capsule actually
/// is.
public enum PingStackLayout {
    public static let visibleLimit = 3
    public static let gap: CGFloat = 8
    public static let collapsedHeight: CGFloat = 44
    /// The row `layout` appends when items are hidden behind "+N more".
    public static let overflowID = "__overflow__"

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
            rows.append(Row(id: overflowID, y: y, height: collapsedHeight))
            y += collapsedHeight + gap
        }
        let total = rows.isEmpty ? 0 : y - gap
        return Result(rows: rows, overflow: overflow, totalHeight: total)
    }
}
