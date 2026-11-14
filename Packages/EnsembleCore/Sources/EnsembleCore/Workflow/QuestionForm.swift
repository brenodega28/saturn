import Foundation

public struct QuestionForm: Sendable, Hashable {
    public static let skippedAnswer = "No preference; use your judgment."

    public var intro: String
    public var questions: [HumanQuestion]

    public init(intro: String, questions: [HumanQuestion]) {
        self.intro = intro
        self.questions = questions
    }

    public init(item: ChatRequest) {
        if let questions = item.questions, !questions.isEmpty {
            self.init(intro: item.body.trimmingCharacters(in: .whitespacesAndNewlines), questions: questions)
        } else {
            self = Self.parse(item.body.isEmpty ? item.title : item.body)
        }
    }

    public var isMultiStep: Bool { questions.count > 1 }

    public static func parse(_ text: String) -> QuestionForm {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var introLines: [String] = []
        var items: [[String]] = []
        for line in trimmed.components(separatedBy: .newlines) {
            if let (number, rest) = numberedItem(line), number == items.count + 1 {
                items.append([rest])
            } else if items.isEmpty {
                introLines.append(line)
            } else {
                items[items.count - 1].append(line)
            }
        }
        guard items.count > 1 else {
            return QuestionForm(intro: "", questions: [HumanQuestion(question: trimmed, options: letteredOptions(in: trimmed))])
        }
        let questions = items.map { lines in
            let question = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return HumanQuestion(question: question, options: letteredOptions(in: question))
        }
        return QuestionForm(intro: introLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), questions: questions)
    }

    public func reply(_ answers: [String]) -> String {
        let cleaned = questions.indices.map { index in
            let answer = index < answers.count ? answers[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return answer.isEmpty ? Self.skippedAnswer : answer
        }
        guard isMultiStep else { return cleaned.first ?? "" }
        return cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        guard let match = line.firstMatch(of: /^\s*(\d{1,2})[.)]\s+(.*)$/), let number = Int(match.1) else { return nil }
        return (number, String(match.2))
    }

    static func letteredOptions(in question: String) -> [String] {
        let markers = question.matches(of: /\(([a-z])\)\s/)
        var options: [String] = []
        for (index, marker) in markers.enumerated() {
            let expected = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(index)))
            guard marker.1.first == expected else { break }
            let end = index + 1 < markers.count ? markers[index + 1].range.lowerBound : question.endIndex
            var option = String(question[marker.range.upperBound..<end])
            if index + 1 == markers.count, let sentenceEnd = option.firstMatch(of: /[.?](\s|$)/) {
                option = String(option[..<sentenceEnd.range.lowerBound])
            }
            option = option.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [";", ",", " or", " and"] where option.hasSuffix(suffix) {
                option = String(option.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
            if !option.isEmpty { options.append(option) }
        }
        return options.count > 1 ? options : []
    }
}
