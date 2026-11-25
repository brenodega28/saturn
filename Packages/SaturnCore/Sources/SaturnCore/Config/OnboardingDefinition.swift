import Foundation
import Yams

public struct OnboardingDefinition: Sendable, Hashable, Codable {
    public var version: Int
    public var forceOnboarding: Bool
    public var instructions: String

    public init(version: Int, forceOnboarding: Bool = false, instructions: String = "") {
        self.version = version
        self.forceOnboarding = forceOnboarding
        self.instructions = instructions
    }

    enum CodingKeys: String, CodingKey {
        case version, instructions
        case forceOnboarding = "force_onboarding"
    }

    public static let bundled = load()

    public static func load() -> OnboardingDefinition {
        guard let url = Bundle.module.url(forResource: "Onboarding", withExtension: nil)?.appending(path: "onboarding.yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let definition = try? YAMLDecoder().decode(OnboardingDefinition.self, from: text) else {
            return OnboardingDefinition(version: 1)
        }
        return definition
    }

    public func needsOnboarding(repository: URL) -> Bool {
        guard ProjectConfigLoader.hasConfig(repository: repository) else { return true }
        return forceOnboarding && version > OnboardingRecord.recordedVersion(in: repository)
    }
}

public struct OnboardingRecord: Sendable, Hashable, Codable {
    public static let fileName = "onboarding.yaml"

    public var version: Int
    public var completedAt: Date

    public init(version: Int, completedAt: Date) {
        self.version = version
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case version
        case completedAt = "completed_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        let stamp = try container.decodeIfPresent(String.self, forKey: .completedAt) ?? ""
        self.completedAt = (try? Date(stamp, strategy: .iso8601)) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(completedAt.formatted(.iso8601), forKey: .completedAt)
    }

    public static var relativePath: String { "\(ProjectConfig.directoryName)/\(fileName)" }

    public static func file(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: fileName)
    }

    public static func load(repository: URL) -> OnboardingRecord? {
        guard let text = try? String(contentsOf: file(in: repository), encoding: .utf8) else { return nil }
        return try? YAMLDecoder().decode(OnboardingRecord.self, from: text)
    }

    public static func recordedVersion(in repository: URL) -> Int {
        load(repository: repository)?.version ?? 0
    }
}
