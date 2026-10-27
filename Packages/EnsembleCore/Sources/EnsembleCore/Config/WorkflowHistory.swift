import Foundation
import Yams

public struct WorkflowVersion: Sendable, Hashable, Codable, Identifiable {
    public var version: Int
    public var note: String
    public var savedAt: Date
    public var snapshot: String

    public var id: Int { version }

    public init(version: Int, note: String, savedAt: Date, snapshot: String) {
        self.version = version
        self.note = note
        self.savedAt = savedAt
        self.snapshot = snapshot
    }

    enum CodingKeys: String, CodingKey {
        case version, note, snapshot
        case savedAt = "saved_at"
    }

    public var workflow: WorkflowDefinition? {
        try? YAMLDecoder().decode(WorkflowDefinition.self, from: snapshot)
    }
}

public struct WorkflowVersionStats: Sendable, Hashable, Identifiable {
    public var version: WorkflowVersion
    public var runs: Int
    public var averageCostUSD: Double?
    public var activeRuns: Int

    public var id: Int { version.version }
}

extension ProjectConfigLoader {
    public static func historyFile(for workflowID: String, repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: "history/\(workflowID).yaml")
    }

    public static func history(of workflowID: String, repository: URL) -> [WorkflowVersion] {
        guard let text = try? String(contentsOf: historyFile(for: workflowID, repository: repository), encoding: .utf8),
              let versions = try? YAMLDecoder().decode([WorkflowVersion].self, from: text) else { return [] }
        return versions.sorted { $0.version > $1.version }
    }

    @discardableResult
    public static func save(
        _ draft: WorkflowDefinition, comparedTo saved: WorkflowDefinition?, note: String, repository: URL, now: Date = .now
    ) throws -> WorkflowDefinition {
        let written = try save(draft, comparedTo: saved, repository: repository)
        var versions = history(of: written.id, repository: repository)
        if let saved, saved.version != written.version, !versions.contains(where: { $0.version == saved.version }) {
            versions.append(WorkflowVersion(version: saved.version, note: "", savedAt: now, snapshot: try encodeYAML(saved)))
        }
        let existing = versions.first { $0.version == written.version }
        versions.removeAll { $0.version == written.version }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = existing?.note ?? (saved == nil ? "First version" : "")
        versions.append(WorkflowVersion(
            version: written.version, note: trimmed.isEmpty ? fallback : trimmed, savedAt: existing?.savedAt ?? now, snapshot: try encodeYAML(written)
        ))
        let file = historyFile(for: written.id, repository: repository)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodeYAML(versions.sorted { $0.version < $1.version }).write(to: file, atomically: true, encoding: .utf8)
        return written
    }

    @discardableResult
    public static func restore(_ version: WorkflowVersion, of current: WorkflowDefinition, repository: URL, now: Date = .now) throws -> WorkflowDefinition {
        guard var restored = version.workflow else { throw CocoaError(.fileReadCorruptFile) }
        restored.id = current.id
        restored.version = current.version
        return try save(restored, comparedTo: current, note: "Restored v\(version.version)", repository: repository, now: now)
    }
}

extension AppDatabase {
    public func versionStats(of workflowID: String, projectId: Int64, versions: [WorkflowVersion]) throws -> [WorkflowVersionStats] {
        let runs = try self.runs(projectId: projectId).filter { $0.workflow == workflowID }
        return versions.map { version in
            let mine = runs.filter { $0.workflowVersion == String(version.version) }
            let finished = mine.filter { !$0.isActive }
            let average = finished.isEmpty ? nil : finished.reduce(0) { $0 + $1.costUSD } / Double(finished.count)
            return WorkflowVersionStats(version: version, runs: mine.count, averageCostUSD: average, activeRuns: mine.count { $0.isActive })
        }
    }
}
