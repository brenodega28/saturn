import Foundation

public enum ModelCatalog {
    public static let fullNames = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    public static var knownModels: [String] {
        AgentModel.allCases.map(\.rawValue) + fullNames
    }

    public static func isValid(_ model: String) -> Bool {
        AgentModel(rawValue: model) != nil || (model.hasPrefix("claude-") && model.count > "claude-".count && !model.contains(where: \.isWhitespace))
    }

    public static func suggestions(matching query: String, including extraModels: [String] = []) -> [String] {
        let candidates = (knownModels + extraModels.filter(isValid)).reduce(into: [String]()) { result, model in
            if !result.contains(model) { result.append(model) }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return candidates }
        let matches = candidates.filter { model in
            model.lowercased().contains(needle) || title(for: model).lowercased().contains(needle)
        }
        return matches.filter { $0.lowercased().hasPrefix(needle) } + matches.filter { !$0.lowercased().hasPrefix(needle) }
    }

    public static func title(for model: String) -> String {
        AgentModel(rawValue: model)?.title ?? model
    }

    public static func detail(for model: String) -> String {
        AgentModel(rawValue: model) != nil ? "Latest" : "Pinned"
    }
}
