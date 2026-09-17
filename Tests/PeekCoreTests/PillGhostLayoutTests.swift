import Testing
@testable import PeekCore

private func item(_ id: String, _ state: SessionState, _ lastEvent: Int64) -> PillGhostLayout.Item {
    PillGhostLayout.Item(id: id, state: state, lastEvent: lastEvent)
}

@Suite struct PillGhostLayoutTests {
    @Test func fewerThanSlotsShowsAllNoOverflow() {
        let items = [item("a", .idle, 1), item("b", .working, 2)]
        let result = PillGhostLayout.selectShown(items)
        #expect(result.shown.count == 2)
        #expect(result.overflow == 0)
    }

    @Test func exactlySlotsNoOverflow() {
        let items = (0..<PillGhostLayout.visibleSlots).map { item("\($0)", .idle, Int64($0)) }
        let result = PillGhostLayout.selectShown(items)
        #expect(result.shown.count == PillGhostLayout.visibleSlots)
        #expect(result.overflow == 0)
    }

    @Test func moreThanSlotsFoldsTheRestIntoOverflow() {
        let items = (0..<(PillGhostLayout.visibleSlots + 3)).map { item("\($0)", .idle, Int64($0)) }
        let result = PillGhostLayout.selectShown(items)
        #expect(result.shown.count == PillGhostLayout.visibleSlots)
        #expect(result.overflow == 3)
    }

    @Test func needsYouAlwaysBeatsWorkingAndIdle() {
        // Slots for two, one of each state plus a lone needsYou arriving
        // last (oldest lastEvent) -- it still has to win a slot.
        let items = [
            item("idle", .idle, 100),
            item("working", .working, 90),
            item("needs", .needsYou, 1),
        ]
        let result = PillGhostLayout.selectShownCapped(items, slots: 2)
        #expect(result.shown == ["needs", "working"])
        #expect(result.overflow == 1)
    }

    @Test func workingBeatsIdleAndDoneRegardlessOfRecency() {
        let items = [
            item("idle-newer", .idle, 100),
            item("done-newer", .done, 99),
            item("working-older", .working, 1),
        ]
        let result = PillGhostLayout.selectShownCapped(items, slots: 1)
        #expect(result.shown == ["working-older"])
    }

    @Test func withinATierMostRecentActivityWins() {
        let items = [
            item("old", .idle, 1),
            item("new", .idle, 100),
            item("mid", .done, 50),
        ]
        let result = PillGhostLayout.selectShownCapped(items, slots: 2)
        #expect(result.shown == ["new", "mid"])
        #expect(result.overflow == 1)
    }

    @Test func aNeedsYouSessionNeverHidesBehindTheBadgeEvenWhenOutnumbered() {
        // Five needsYou sessions, two slots: overflow still exists (the pill
        // can't grow), but every hidden session's count is honest -- the
        // three that don't fit are exactly the ones dropped, no idle/done/
        // working session ever displaces a needsYou one out of the visible set.
        let items = (0..<5).map { item("needs-\($0)", .needsYou, Int64($0)) }
            + [item("idle", .idle, 999)]
        let result = PillGhostLayout.selectShownCapped(items, slots: 2)
        #expect(result.shown.allSatisfy { $0.hasPrefix("needs-") })
        #expect(result.overflow == 4)
    }

    @Test func emptyIsEmpty() {
        let result = PillGhostLayout.selectShown([])
        #expect(result.shown.isEmpty)
        #expect(result.overflow == 0)
    }
}
