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
}
