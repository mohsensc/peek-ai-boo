import Foundation
import Testing
@testable import PeekCore

@Suite struct DecideReplyTests {
    @Test func allowBytes() {
        #expect(DecideReply.allow.line == Data(#"{"decision":"allow"}"#.utf8))
    }

    @Test func bareDenyLeavesMessageOut() {
        #expect(DecideReply.deny(message: nil).line == Data(#"{"decision":"deny"}"#.utf8))
    }

    @Test func denyMessageKeyComesAfterDecision() {
        let line = String(decoding: DecideReply.deny(message: "no").line, as: UTF8.self)
        #expect(line == #"{"decision":"deny","message":"no"}"#)
    }

    @Test func awkwardMessageSurvivesRoundTrip() throws {
        let message = "say \"hi\" \\ then\nnext line 👻 / done\u{0}\u{2028}"
        let line = DecideReply.deny(message: message).line
        // The hook reads up to the first newline, so one inside would cut
        // the reply short and it'd be dropped as garbage.
        #expect(!line.contains(0x0A))
        let obj = try #require(JSONSerialization.jsonObject(with: line) as? [String: String])
        #expect(obj == ["decision": "deny", "message": message])
    }

    @Test func answerMessageSurvivesRoundTrip() throws {
        let message = #"User has answered your questions: "Which color?"="Red". You can now continue with the user's answers in mind."#
        let line = DecideReply.deny(message: message).line
        let obj = try #require(JSONSerialization.jsonObject(with: line) as? [String: String])
        #expect(obj["message"] == message)
        // Slashes don't need escaping and the hook copies the token raw, so
        // keep it readable.
        #expect(!String(decoding: DecideReply.deny(message: "a/b").line, as: UTF8.self).contains(#"\/"#))
    }
}
