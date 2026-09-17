import Foundation

/// One entry of AskUserQuestion's `tool_input.questions`.
public struct Question: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String
        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public let question: String
    public let header: String
    public let options: [Option]
    public let multiSelect: Bool

    public init(question: String, header: String, options: [Option], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// nil unless every question has a question, header and at least one
    /// labeled option. description and multiSelect only change how it's
    /// drawn, so they default to "" and false.
    public static func parse(_ toolInput: JSONValue?) -> [Question]? {
        guard let items = toolInput?["questions"]?.arrayValue, !items.isEmpty else { return nil }
        var result: [Question] = []
        for item in items {
            guard let question = item["question"]?.stringValue,
                  let header = item["header"]?.stringValue,
                  let rawOptions = item["options"]?.arrayValue, !rawOptions.isEmpty
            else { return nil }
            var options: [Option] = []
            for raw in rawOptions {
                guard let label = raw["label"]?.stringValue else { return nil }
                options.append(Option(label: label, description: raw["description"]?.stringValue ?? ""))
            }
            var multiSelect = false
            if let flag = item["multiSelect"] {
                guard let b = flag.boolValue else { return nil }
                multiSelect = b
            }
            result.append(Question(question: question, header: header, options: options, multiSelect: multiSelect))
        }
        return result
    }

    /// answers[i] is the labels picked for question i, in option order.
    /// Mirrors the text Claude's own picker sends back.
    public static func answerMessage(_ questions: [Question], answers: [[String]]) -> String {
        let pairs = questions.indices.map { i in
            let picked = i < answers.count ? answers[i] : []
            return "\"\(questions[i].question)\"=\"\(picked.joined(separator: ", "))\""
        }
        return "User has answered your questions: \(pairs.joined(separator: ", ")). "
            + "You can now continue with the user's answers in mind."
    }

    /// Same, plus raw "Other" text per question index. This is the one
    /// path from what the user typed to what's on the wire: clean, then
    /// escape, then fold into that question's picks (replacing them for a
    /// single-choice question, alongside them for multiSelect) before
    /// building the message. A caller can't get the encoding wrong because
    /// it never sees the escaped form.
    public static func answerMessage(
        _ questions: [Question], answers: [[String]], typed: [Int: String]
    ) -> String {
        let merged = questions.indices.map { i -> [String] in
            let picked = i < answers.count ? answers[i] : []
            guard let raw = typed[i], let clean = cleanTypedAnswer(raw) else { return picked }
            let escaped = escapeTypedAnswer(clean)
            return questions[i].multiSelect ? picked + [escaped] : [escaped]
        }
        return answerMessage(questions, answers: merged)
    }

    /// Exactly two options, single-select, short enough to draw as two
    /// small glass buttons in row 1 itself — replacing the deny/allow slot
    /// an approval gets — instead of needing the expanded card. A rough
    /// character budget rather than real text measurement — same "good
    /// enough" spirit as the panel's own row-height estimates — so this
    /// stays a cheap, pure check the view layer can call before laying
    /// anything out. Three or more options, multiSelect, or going over
    /// budget all fall through to the "asks · N" count-and-expand row.
    public static let inlineOptionCount = 2
    public static let inlineMaxChars = 16

    public var fitsInline: Bool {
        guard options.count == Self.inlineOptionCount, !multiSelect else { return false }
        let chars = options.reduce(0) { $0 + $1.label.count }
        return chars <= Self.inlineMaxChars
    }

    /// Row 1's "asks · N" for a question that doesn't fit inline: every
    /// option across every question, since that's what's actually left to
    /// answer — not just how many questions there are.
    public static func expandCount(_ questions: [Question]) -> Int {
        questions.reduce(0) { $0 + $1.options.count }
    }

    /// A one-line "Other" field doesn't need much room, and this keeps a
    /// pasted essay from blowing up the message.
    public static let typedAnswerCap = 200

    /// Flattens newlines to spaces, trims, and caps length. nil for empty
    /// or whitespace-only input. This is the value the UI keeps and shows;
    /// escaping only happens when it's folded into the answer message.
    public static func cleanTypedAnswer(_ raw: String) -> String? {
        let flattened = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(typedAnswerCap))
    }

    /// Escapes backslash then quote, so embedding a typed answer inside
    /// the message's quoted segment can't be misread as the message's own
    /// quoting. Backslash first, so escaping a quote can't double an
    /// already-escaped backslash.
    static func escapeTypedAnswer(_ clean: String) -> String {
        clean
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
