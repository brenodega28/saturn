import Foundation

public enum ToolCheck: Sendable, Equatable {
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

public enum ProviderAccess: Sendable, Equatable {
    case apiKey
    case claudeLogin(method: String?)
    case none

    public var isOK: Bool { self != .none }
}

public struct EnvironmentReport: Sendable, Equatable {
    public let git: ToolCheck
    public let claude: ToolCheck
    public let provider: ProviderAccess

    public var isReady: Bool { git.isOK && claude.isOK && provider.isOK }
}

public struct EnvironmentChecker: Sendable {
    private let locator: ToolLocator
    private let runner: CommandRunner
    private let secrets: any SecretStore

    public init(locator: ToolLocator, runner: CommandRunner, secrets: any SecretStore) {
        self.locator = locator
        self.runner = runner
        self.secrets = secrets
    }

    public func check() async -> EnvironmentReport {
        async let git = checkTool("git", versionArguments: ["--version"])
        async let claude = checkTool("claude", versionArguments: ["--version"])
        let claudeCheck = await claude
        return EnvironmentReport(
            git: await git,
            claude: claudeCheck,
            provider: await providerAccess(claude: claudeCheck)
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

    func providerAccess(claude: ToolCheck) async -> ProviderAccess {
        if let key = try? secrets.read(.anthropicAPIKey), !key.trimmed.isEmpty {
            return .apiKey
        }
        guard case .found(let path, _) = claude,
              let result = try? await runner.run(path, ["auth", "status", "--json"]),
              let status = Self.claudeAuthStatus(from: result.standardOutput),
              status.loggedIn
        else {
            return .none
        }
        return .claudeLogin(method: status.authMethod)
    }

    struct ClaudeAuthStatus: Decodable, Equatable {
        let loggedIn: Bool
        let authMethod: String?
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
