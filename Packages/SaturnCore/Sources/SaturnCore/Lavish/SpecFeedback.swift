import Foundation

public enum SpecFeedback {
    public static let heading = "Spec feedback from the review page"

    public enum Target: Equatable, Sendable {
        case criterion(index: Int, text: String)
        case section(String)
        case element(String)
        case page
    }

    public static func message(for prompts: [LavishPrompt], document: SpecDocument?) -> String? {
        let notes = prompts.filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.attachments.isEmpty }
        guard !notes.isEmpty else { return nil }
        let version = document.map { " on v\($0.version) “\($0.title)”" } ?? ""
        let lines = notes.enumerated().map { index, prompt in
            var line = "\(index + 1). \(describe(target(of: prompt, in: document))): \(prompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
            let paths = prompt.attachments.compactMap { $0.path ?? $0.name }
            if !paths.isEmpty { line += "\n   Attachments: " + paths.joined(separator: ", ") }
            return line
        }
        return "\(heading)\(version):\n\n" + lines.joined(separator: "\n")
    }

    public static func leadPrompt(_ message: String) -> String {
        """
        \(message)

        ---
        Saturn note (not written by the user): this is the user’s feedback from the spec review page in Lavish. Revise the spec with `\(HandoffTool.draftSpec.qualifiedName)` when it calls for changes; the page re-renders and reloads. Then answer on the page with `\(HandoffTool.replySpec.qualifiedName)`, which marks these notes done.
        """
    }

    public static func target(of prompt: LavishPrompt, in document: SpecDocument?) -> Target {
        if let id = capture("criterion-([0-9a-f]+(?:-[0-9]+)?)", in: prompt.selector), let document {
            let ids = SpecPageRenderer.criterionIDs(document.acceptanceCriteria)
            if let index = ids.firstIndex(of: id) {
                return .criterion(index: index + 1, text: document.acceptanceCriteria[index].text)
            }
        }
        if let id = capture("section-([a-z0-9-]+)", in: prompt.selector) {
            let headings = ["Summary", "Interfaces", "Out of scope", "Acceptance criteria", "Verification", "Workers"] + (document?.extraSections.map(\.heading) ?? [])
            if let heading = headings.first(where: { SpecPageRenderer.sectionID($0) == "section-\(id)" }) { return .section(heading) }
        }
        if prompt.selector.contains("spec-header") { return .section("Title") }
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return .element(text) }
        return .page
    }

    static func describe(_ target: Target) -> String {
        switch target {
        case .criterion(let index, let text): "On criterion \(index) “\(clip(text))”"
        case .section(let heading): "On \(heading)"
        case .element(let text): "On “\(clip(text))”"
        case .page: "On the whole spec"
        }
    }

    static func clip(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
