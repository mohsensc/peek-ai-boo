/// One question's "Other" free-text affordance: closed until tapped, open
/// while typing, committed once. A view only calls these; the state machine
/// is what's tested, since SwiftUI state isn't.
public struct OtherAnswer: Sendable, Equatable {
    public private(set) var isOpen = false
    public private(set) var text = ""
    /// True once `submit` has produced a clean answer. A view uses this to
    /// show a filled "Other: ..." pill and to count the question as
    /// answered. Named apart from "sent" on purpose: this is local commit
    /// state, not confirmation the hook got a reply.
    public private(set) var committed = false

    public init() {}

    public mutating func open() {
        guard !committed else { return }
        isOpen = true
    }

    public mutating func type(_ text: String) {
        guard isOpen, !committed else { return }
        self.text = text
    }

    /// Esc: back to the option list, typed text dropped. A no-op once
    /// committed — that answer already stands.
    public mutating func cancel() {
        guard isOpen, !committed else { return }
        isOpen = false
        text = ""
    }

    /// The cleaned text to use, or nil (leaving the field open) for empty,
    /// whitespace-only, or already-committed input. Sets `committed` so a
    /// second call — a double Enter, or Enter racing the send button — is
    /// a no-op.
    @discardableResult
    public mutating func submit() -> String? {
        guard isOpen, !committed, let clean = Question.cleanTypedAnswer(text) else { return nil }
        text = clean
        committed = true
        isOpen = false
        return clean
    }
}
