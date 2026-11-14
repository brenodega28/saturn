import Foundation

public enum ToolCheck: Sendable, Hashable, Codable {
    case found(path: URL, version: String)
    case missing
    case broken(path: URL, message: String)

    public var isOK: Bool {
        if case .found = self { return true }
        return false
    }

    public var path: URL? {
        switch self {
        case .found(let path, _), .broken(let path, _): path
        case .missing: nil
        }
    }
}

public enum ProviderStatus: Sendable, Hashable, Codable {
    case notChosen
    case apiKey(isStored: Bool)
    case claudeSignIn(account: String?, isSignedIn: Bool)

    public var mode: ProviderMode? {
        switch self {
        case .notChosen: nil
        case .apiKey: .apiKey
        case .claudeSignIn: .claudeSignIn
        }
    }

    public var isOK: Bool {
        switch self {
        case .notChosen: false
        case .apiKey(let isStored): isStored
        case .claudeSignIn(_, let isSignedIn): isSignedIn
        }
    }
}

public struct EnvironmentReport: Sendable, Hashable, Codable {
    public let git: ToolCheck
    public let claude: ToolCheck
    public let provider: ProviderStatus

    public var isReady: Bool { git.isOK && claude.isOK && provider.isOK }
}

public struct EnvironmentChecker: Sendable {
    private let locator: ToolLocator
    private let runner: CommandRunner
    private let secrets: any SecretStore
    private let mode: ProviderMode?

    public init(locator: ToolLocator, runner: CommandRunner, secrets: any SecretStore, mode: ProviderMode?) {
        self.locator = locator
        self.runner = runner
        self.secrets = secrets
        self.mode = mode
    }

    public func check() async -> EnvironmentReport {
        async let git = checkTool("git", versionArguments: ["--version"])
        async let claude = checkTool("claude", versionArguments: ["--version"])
        let claudeCheck = await claude
        return EnvironmentReport(
            git: await git,
            claude: claudeCheck,
            provider: await providerStatus(claude: claudeCheck)
        )
    }

    func checkTool(_ name: String, versionArguments: [String]) async -> ToolCheck {
        guard let path = locator.locate(name) else { return .missing }
        do {
            let result = try await runner.run(path, versionArguments)
            guard result.succeeded else {
                return .broken(path: path, message: (result.standardError + result.standardOutput).trimmed)
            }
            return .found(path: path, version: Self.version(from: result.standardOutput))
        } catch {
            return .broken(path: path, message: error.localizedDescription)
        }
    }

    func providerStatus(claude: ToolCheck) async -> ProviderStatus {
        switch mode {
        case nil:
            return .notChosen
        case .apiKey:
            let key = (try? secrets.read(.anthropicAPIKey)) ?? nil
            return .apiKey(isStored: !(key?.trimmed.isEmpty ?? true))
        case .claudeSignIn:
            let signInRunner = CommandRunner(environment: ProviderMode.claudeSignIn.environment(base: runner.environment, apiKey: nil))
            guard case .found(let path, _) = claude,
                  let result = try? await signInRunner.run(path, ["auth", "status", "--json"]),
                  let status = Self.claudeAuthStatus(from: result.standardOutput)
            else {
                return .claudeSignIn(account: nil, isSignedIn: false)
            }
            let isSignedIn = status.loggedIn && status.authMethod != "api_key"
            return .claudeSignIn(account: isSignedIn ? status.email : nil, isSignedIn: isSignedIn)
        }
    }

    struct ClaudeAuthStatus: Decodable, Equatable {
        let loggedIn: Bool
        let authMethod: String?
        let email: String?
    }

    static func claudeAuthStatus(from output: String) -> ClaudeAuthStatus? {
        try? JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(output.utf8))
    }

    static func version(from output: String) -> String {
        let firstLine = output.trimmed.split(separator: "\n").first.map(String.init) ?? ""
        let pattern = /\d+(\.\d+)+/
        return firstLine.firstMatch(of: pattern).map { String($0.output.0) } ?? firstLine
    }
}
