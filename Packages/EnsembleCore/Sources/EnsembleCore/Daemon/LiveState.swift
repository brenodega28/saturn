import Foundation

public struct LiveRetry: Codable, Sendable, Hashable {
    public var attempt: Int
    public var maxRetries: Int
    public var delayMS: Int
    public var status: Int?
    public var error: String?

    init(_ retry: APIRetry) {
        attempt = retry.attempt
        maxRetries = retry.maxRetries
        delayMS = retry.delayMS
        status = retry.status
        error = retry.error
    }
}

public struct LiveAgent: Codable, Sendable, Hashable {
    public var isRunning = false
    public var isStopping = false
    public var isQueued = false
    public var canResume = false
    public var isSettingUp = false
    public var setupFailed = false
    public var isUpdatingMemory = false
    public var queuedMessages: [String] = []
    public var lastOutputAt: Date?
    public var retryingAt: Date?
    public var apiRetry: LiveRetry?

    public init() {}
}

public struct DaemonEnvironment: Codable, Sendable, Hashable {
    public var gitPath: String?
    public var claudePath: String?
    public var claudeProblem: String?
    public var gitProblem: String?
    public var providerMode: ProviderMode?
    public var providerReady: Bool
    public var providerProblem: String?
    public var hostName: String
    public var homeDirectory: String
    public var fileVaultOn: Bool?
    public var report: EnvironmentReport?
    public var processEnvironment: [String: String] = [:]

    public init(
        gitPath: String? = nil, claudePath: String? = nil, claudeProblem: String? = nil, gitProblem: String? = nil,
        providerMode: ProviderMode? = nil, providerReady: Bool = false, providerProblem: String? = nil,
        hostName: String = ProcessInfo.processInfo.hostName, homeDirectory: String = NSHomeDirectory(), fileVaultOn: Bool? = nil
    ) {
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.claudeProblem = claudeProblem
        self.gitProblem = gitProblem
        self.providerMode = providerMode
        self.providerReady = providerReady
        self.providerProblem = providerProblem
        self.hostName = hostName
        self.homeDirectory = homeDirectory
        self.fileVaultOn = fileVaultOn
    }
}

public struct LiveState: Codable, Sendable, Hashable {
    public var agents: [Int64: LiveAgent] = [:]
    public var drivingRunIDs: Set<Int64> = []
    public var waitingForCapacity: Set<Int64> = []
    public var apiCooldownUntil: Date?
    public var usageRevision = 0
    public var environment = DaemonEnvironment()
    public var mcpReady = false
    public var startedAt = Date()

    public init() {}

    public func agent(_ id: Int64?) -> LiveAgent {
        id.flatMap { agents[$0] } ?? LiveAgent()
    }

    public var activeRunCount: Int { drivingRunIDs.count }
}

extension SetupRecord {
    public static func decoded(from data: Data) -> SetupRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SetupRecord.self, from: data)
    }
}
