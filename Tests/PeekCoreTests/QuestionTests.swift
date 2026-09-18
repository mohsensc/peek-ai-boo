import Foundation
import Testing
@testable import PeekCore

private func input(_ json: String) -> JSONValue? {
    JSONValue.parse(Data(json.utf8))
}

private let color = Question(
    question: "Which color?", header: "Color",
    options: [.init(label: "Red", description: ""), .init(label: "Blue", description: "")],
    multiSelect: false
)

@Suite struct QuestionTests {
    @Test func parsesDesignDocShape() throws {
        let qs = try #require(Question.parse(input("""
        {"questions":[
          {"question":"Which color?","header":"Color","multiSelect":false,
           "options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}]},
          {"question":"Which sizes?","header":"Size","multiSelect":true,
           "options":[{"label":"S","description":"small"},{"label":"M","description":"medium"}]}
        ]}
        """)))
        #expect(qs.count == 2)
        #expect(qs[0].question == "Which color?")
        #expect(qs[0].header == "Color")
        #expect(qs[0].options == [.init(label: "Red", description: "warm"), .init(label: "Blue", description: "cool")])
        #expect(qs[0].multiSelect == false)
        #expect(qs[1].multiSelect == true)
    }

    @Test func missingRequiredFieldsGiveNil() {
        let cases = [
            #"{}"#,
            #"{"questions":[]}"#,
            #"{"questions":"nope"}"#,
            #"{"questions":[{"header":"H","options":[{"label":"A"}]}]}"#,
            #"{"questions":[{"question":"Q","options":[{"label":"A"}]}]}"#,
            #"{"questions":[{"question":"Q","header":"H"}]}"#,
            #"{"questions":[{"question":"Q","header":"H","options":[]}]}"#,
            #"{"questions":[{"question":"Q","header":"H","options":[{"description":"d"}]}]}"#,
            #"{"questions":[{"question":"Q","header":"H","options":[{"label":"A"}],"multiSelect":"yes"}]}"#,
            // one bad question spoils the lot: a partial picker can't
            // produce an answer Claude would accept
            #"{"questions":[{"question":"Q","header":"H","options":[{"label":"A"}]},{"question":"R"}]}"#,
        ]
        for json in cases {
            #expect(Question.parse(input(json)) == nil, "\(json)")
        }
        #expect(Question.parse(nil) == nil)
    }

    @Test func descriptionAndMultiSelectAreOptional() throws {
        // Display-only fields. Missing multiSelect reads as single choice,
        // which is what Claude assumes too.
        let qs = try #require(Question.parse(input(
            #"{"questions":[{"question":"Q","header":"H","options":[{"label":"A"}]}]}"#
        )))
        #expect(qs[0].options == [.init(label: "A", description: "")])
        #expect(qs[0].multiSelect == false)
    }

    @Test func singleAnswerMatchesDesignDoc() {
        let message = Question.answerMessage([color], answers: [["Red"]])
        #expect(Data(message.utf8) == Data(
            #"User has answered your questions: "Which color?"="Red". You can now continue with the user's answers in mind."#.utf8
        ))
    }

    @Test func twoQuestionsJoinWithCommaSpace() {
        let size = Question(
            question: "Which size?", header: "Size",
            options: [.init(label: "S", description: ""), .init(label: "L", description: "")],
            multiSelect: false
        )
        let message = Question.answerMessage([color, size], answers: [["Blue"], ["L"]])
        #expect(message == #"User has answered your questions: "Which color?"="Blue", "Which size?"="L". You can now continue with the user's answers in mind."#)
    }

    @Test func multiSelectLabelsJoinInsideQuotes() {
        let toppings = Question(
            question: "Which toppings?", header: "Toppings",
            options: [.init(label: "Cheese", description: ""), .init(label: "Olives", description: ""),
                      .init(label: "Basil", description: "")],
            multiSelect: true
        )
        let message = Question.answerMessage([color, toppings], answers: [["Red"], ["Cheese", "Basil"]])
        #expect(message == #"User has answered your questions: "Which color?"="Red", "Which toppings?"="Cheese, Basil". You can now continue with the user's answers in mind."#)
    }

    // MARK: "Other" typed text

    @Test func cleanTypedAnswerFlattensNewlines() {
        #expect(Question.cleanTypedAnswer("first line\r\nsecond\nthird\rfourth") == "first line second third fourth")
    }

    @Test func cleanTypedAnswerKeepsUnicode() throws {
        let clean = try #require(Question.cleanTypedAnswer("café 🎉 日本語"))
        #expect(clean == "café 🎉 日本語")
        #expect(Question.escapeTypedAnswer(clean) == clean)   // nothing to escape
    }

    @Test func cleanTypedAnswerRejectsEmptyOrWhitespaceOnly() {
        #expect(Question.cleanTypedAnswer("") == nil)
        #expect(Question.cleanTypedAnswer("   ") == nil)
        #expect(Question.cleanTypedAnswer("\n\t  \r") == nil)
    }

    @Test func cleanTypedAnswerCapsLength() {
        let long = String(repeating: "a", count: Question.typedAnswerCap + 40)
        #expect(Question.cleanTypedAnswer(long) == String(repeating: "a", count: Question.typedAnswerCap))
    }

    @Test func escapeTypedAnswerEscapesBackslashBeforeQuote() throws {
        let clean = try #require(Question.cleanTypedAnswer(#"He said "go" and used a\b"#))
        #expect(Question.escapeTypedAnswer(clean) == #"He said \"go\" and used a\\b"#)
    }

    @Test func answerMessageEncodesTypedAnswerWithQuotes() {
        let message = Question.answerMessage([color], answers: [[]], typed: [0: #"the "big" one"#])
        #expect(message == #"User has answered your questions: "Which color?"="the \"big\" one". You can now continue with the user's answers in mind."#)
    }

    @Test func answerMessageReplacesPicksForSingleSelect() {
        // Single-choice: typed text stands alone, any picked option is dropped.
        let message = Question.answerMessage([color], answers: [["Red"]], typed: [0: "Mauve"])
        #expect(message == #"User has answered your questions: "Which color?"="Mauve". You can now continue with the user's answers in mind."#)
    }

    @Test func answerMessageAddsTypedAnswerAlongsideMultiSelectPicks() {
        let toppings = Question(
            question: "Which toppings?", header: "Toppings",
            options: [.init(label: "Cheese", description: "")],
            multiSelect: true
        )
        let message = Question.answerMessage([toppings], answers: [["Cheese"]], typed: [0: "  smoked salmon  "])
        #expect(message == #"User has answered your questions: "Which toppings?"="Cheese, smoked salmon". You can now continue with the user's answers in mind."#)
    }

    @Test func answerMessageIgnoresEmptyOrMissingTypedAnswer() {
        let message = Question.answerMessage([color], answers: [["Red"]], typed: [0: "   "])
        #expect(message == Question.answerMessage([color], answers: [["Red"]]))
    }
}
