import Foundation

public enum ProviderMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case apiKey
    case claudeSignIn

    public var id: Self { self }

    public var title: String {
        switch self {
        case .apiKey: "Anthropic API key"
        case .claudeSignIn: "Claude sign-in"
        }
    }

    public var billing: String {
        switch self {
        case .apiKey: "Billed per token to the Anthropic account that owns the key."
        case .claudeSignIn: "Uses the Claude plan you signed in to with `claude auth login`."
        }
    }

    public var expectedKeySource: String {
        switch self {
        case .apiKey: "ANTHROPIC_API_KEY"
        case .claudeSignIn: "none"
        }
    }

    public func environment(base: [String: String], apiKey: String?) -> [String: String] {
        var environment = base.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDECODE"
        }
        if self == .apiKey, let apiKey {
            environment["ANTHROPIC_API_KEY"] = apiKey
        }
        return environment
    }
}
