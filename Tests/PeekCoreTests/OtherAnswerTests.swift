import Testing
@testable import PeekCore

@Suite struct OtherAnswerTests {
    @Test func startsClosed() {
        let field = OtherAnswer()
        #expect(field.isOpen == false)
        #expect(field.committed == false)
        #expect(field.text == "")
    }

    @Test func openRevealsTheField() {
        var field = OtherAnswer()
        field.open()
        #expect(field.isOpen == true)
    }

    @Test func typingOnlyAppliesWhileOpen() {
        var field = OtherAnswer()
        field.type("ignored")
        #expect(field.text == "")
        field.open()
        field.type("hello")
        #expect(field.text == "hello")
    }

    @Test func cancelClosesAndDropsText() {
        var field = OtherAnswer()
        field.open()
        field.type("hello")
        field.cancel()
        #expect(field.isOpen == false)
        #expect(field.text == "")
        #expect(field.committed == false)
    }

    @Test func cancelWithoutOpeningIsANoOp() {
        var field = OtherAnswer()
        field.cancel()
        #expect(field.isOpen == false)
    }

    @Test func submitCleansAndClosesAndCommits() {
        var field = OtherAnswer()
        field.open()
        field.type("  hello world  ")
        let sent = field.submit()
        #expect(sent == "hello world")
        #expect(field.text == "hello world")
        #expect(field.committed == true)
        #expect(field.isOpen == false)
    }

    @Test func submitRejectsEmptyOrWhitespaceAndStaysOpen() {
        var field = OtherAnswer()
        field.open()
        field.type("   ")
        #expect(field.submit() == nil)
        #expect(field.committed == false)
        #expect(field.isOpen == true)   // stays open so the user can fix it
    }

    @Test func submitWithoutOpeningDoesNothing() {
        var field = OtherAnswer()
        #expect(field.submit() == nil)
        #expect(field.committed == false)
    }

    // "sent at most once, never after resolved" at the state-machine level:
    // once committed, nothing puts the field back into a sendable state.
    @Test func doubleSubmitSendsOnlyOnce() {
        var field = OtherAnswer()
        field.open()
        field.type("hello")
        #expect(field.submit() == "hello")
        #expect(field.submit() == nil)
    }

    @Test func cancelAfterCommitIsANoOp() {
        var field = OtherAnswer()
        field.open()
        field.type("hello")
        _ = field.submit()
        field.cancel()
        #expect(field.committed == true)
        #expect(field.text == "hello")
    }

    @Test func openAfterCommitIsANoOp() {
        var field = OtherAnswer()
        field.open()
        field.type("hello")
        _ = field.submit()
        field.open()
        #expect(field.isOpen == false)
    }

    @Test func typeAfterCommitIsIgnored() {
        var field = OtherAnswer()
        field.open()
        field.type("hello")
        _ = field.submit()
        field.type("changed")
        #expect(field.text == "hello")
    }

    // Ping capsules (row 1's ✎, the expanded card's Other pill) show
    // "selected" as `isOpen || committed` so it reads green from the click
    // through typing until sent, not just once committed — see
    // docs/design.md. This is the truth table both views rely on.
    @Test func activeFromOpenThroughCommitNotJustAfter() {
        func active(_ f: OtherAnswer) -> Bool { f.isOpen || f.committed }
        var field = OtherAnswer()
        #expect(!active(field))
        field.open()
        #expect(active(field))
        field.type("hi")
        #expect(active(field))
        _ = field.submit()
        #expect(active(field))
    }

    @Test func inactiveAgainAfterCancel() {
        func active(_ f: OtherAnswer) -> Bool { f.isOpen || f.committed }
        var field = OtherAnswer()
        field.open()
        field.cancel()
        #expect(!active(field))
    }
}
