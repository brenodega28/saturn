import Foundation

public struct DaemonSettings: Codable, Sendable, Hashable {
    public var providerMode: ProviderMode?
    public var globalMonthlyBudgetUSD: Double?
    public var globalWeeklyBudgetUSD: Double?

    public init(providerMode: ProviderMode? = nil, globalMonthlyBudgetUSD: Double? = nil, globalWeeklyBudgetUSD: Double? = nil) {
        self.providerMode = providerMode
        self.globalMonthlyBudgetUSD = globalMonthlyBudgetUSD
        self.globalWeeklyBudgetUSD = globalWeeklyBudgetUSD
    }
}

enum DaemonFiles {
    static func loadIdentity(paths: AppPaths) throws -> DaemonIdentity {
        if let data = try? Data(contentsOf: paths.daemonIdentity),
           var identity = try? JSONDecoder().decode(DaemonIdentity.self, from: data) {
            if identity.protocolVersion != EnsembleProtocol.version {
                identity.protocolVersion = EnsembleProtocol.version
                try write(identity, to: paths.daemonIdentity)
            }
            return identity
        }
        let identity = DaemonIdentity(id: UUID(), name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        try write(identity, to: paths.daemonIdentity)
        return identity
    }

    static func loadSettings(paths: AppPaths) -> DaemonSettings? {
        guard let data = try? Data(contentsOf: paths.daemonSettings) else { return nil }
        return try? JSONDecoder().decode(DaemonSettings.self, from: data)
    }

    static func saveSettings(_ settings: DaemonSettings, paths: AppPaths) throws {
        try write(settings, to: paths.daemonSettings)
    }

    static func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
