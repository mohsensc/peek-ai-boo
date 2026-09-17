import Foundation

/// Pure geometry for the pill's own ghost row: how many live sessions get a
/// ghost before the rest fold into a "+K" badge, and which ones those are.
/// Mirrors PingStackLayout's shape (a static slot count plus a selection
/// function) so AppKit/SwiftUI never have to duplicate this math.
public enum PillGhostLayout {
    /// Measured, not guessed: `NotchPanel.frame`'s width is
    /// `notch.width + 220`, centered on the notch, so each wing (the black
    /// area beside the actual camera cutout) is a fixed 110pt regardless of
    /// the physical notch's own width -- confirmed with `--print-geometry`
    /// on real hardware (PILL width came back 405 = 185 + 220). Minus the
    /// pill's own 10pt horizontal padding and the 6pt HStack gap before the
    /// center spacer leaves 94pt of true ghost-row budget. At 13pt ghosts
    /// (GhostSheet.size) plus 4pt spacing, N ghosts cost `17N - 4`pt; with
    /// one ~14pt overflow badge (plus its own 4pt gap) reserved for when
    /// it's needed, 4 ghosts (81pt) fit comfortably and 5 (98pt) don't.
    public static let visibleSlots = 4

    /// One live session, as far as slot selection cares.
    public struct Item: Equatable {
        public let id: String
        public let state: SessionState
        public let lastEvent: Int64
        public init(id: String, state: SessionState, lastEvent: Int64) {
            self.id = id
            self.state = state
            self.lastEvent = lastEvent
        }
    }

    public struct Selection: Equatable {
        public let shown: [String]
        public let overflow: Int
    }

    /// needsYou first, then working, then most recent activity -- see
    /// docs/design.md. Capped at `visibleSlots`: the pill never resizes, so
    /// a needsYou session past the cap still can't get a ghost drawn here,
    /// same as a pending approval past the ping stack's own cap folding into
    /// "+N more". It's never silently dropped, though -- it's still counted
    /// in `overflow`, and the pill's separate waiting-count number (right of
    /// the notch) already shows the true needsYou total regardless of how
    /// many of them fit as ghosts.
    public static func selectShown(_ items: [Item]) -> Selection {
        selectShownCapped(items, slots: visibleSlots)
    }

    /// Same ranking as `selectShown`, with an explicit slot count so tests
    /// can check the priority rules without depending on the exact measured
    /// constant.
    public static func selectShownCapped(_ items: [Item], slots: Int) -> Selection {
        let ranked = items.sorted { a, b in
            let ta = tier(a.state), tb = tier(b.state)
            if ta != tb { return ta < tb }
            return a.lastEvent > b.lastEvent
        }
        let shown = ranked.prefix(slots)
        return Selection(shown: shown.map(\.id), overflow: items.count - shown.count)
    }

    private static func tier(_ state: SessionState) -> Int {
        switch state {
        case .needsYou: return 0
        case .working: return 1
        case .idle, .done: return 2
        }
    }
}
