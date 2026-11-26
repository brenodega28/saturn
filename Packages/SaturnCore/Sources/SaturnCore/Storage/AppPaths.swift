import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let dataDirectoryVariable = "SATURN_DATA_DIR"

    public static let standard = resolved(environment: ProcessInfo.processInfo.environment)

    static func resolved(environment: [String: String]) -> AppPaths {
        if let custom = customDataDirectory(in: environment) {
            return AppPaths(root: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        return AppPaths(root: LegacyMigration.defaultRoot)
    }

    static func customDataDirectory(in environment: [String: String]) -> String? {
        [dataDirectoryVariable, LegacyMigration.Legacy.dataDirectoryVariable]
            .compactMap { environment[$0] }
            .first { !$0.isEmpty }
    }

    public var database: URL { root.appending(path: "saturn.sqlite") }

    public var daemonIdentity: URL { root.appending(path: "daemon.json") }

    public var daemonSocket: URL { root.appending(path: "saturnd.sock") }

    public var daemonSettings: URL { root.appending(path: "daemon-settings.json") }

    public var remoteDevices: URL { root.appending(path: "remote-devices.json") }

    public var daemonLog: URL { root.appending(path: "saturnd.log") }

    public var replicasDirectory: URL {
        root.appending(path: "replicas", directoryHint: .isDirectory)
    }

    public func replica(_ daemonID: DaemonID) -> URL {
        replicasDirectory.appending(path: "\(daemonID.uuidString.lowercased()).sqlite")
    }

    public func replicaState(_ daemonID: DaemonID) -> URL {
        replicasDirectory.appending(path: "\(daemonID.uuidString.lowercased()).json")
    }

    public func replicaFiles(_ daemonID: DaemonID) -> URL {
        replicasDirectory.appending(path: "\(daemonID.uuidString.lowercased())-files", directoryHint: .isDirectory)
    }

    public var knownDaemons: URL { root.appending(path: "daemons.json") }

    public func agentDirectory(_ agentID: Int64) -> URL {
        root.appending(path: "agents/\(agentID)", directoryHint: .isDirectory)
    }

    public func transcript(_ agentID: Int64) -> URL {
        agentDirectory(agentID).appending(path: "transcript.jsonl")
    }

    public func evidenceDirectory(runId: Int64) -> URL {
        root.appending(path: "runs/\(runId)/evidence", directoryHint: .isDirectory)
    }

    public func runSpecLink(runId: Int64) -> URL {
        root.appending(path: "runs/\(runId)/spec.json")
    }

    public func specDraftsDirectory(projectId: Int64) -> URL {
        root.appending(path: "specs/\(projectId)", directoryHint: .isDirectory)
    }

    public func specDraft(projectId: Int64, taskId: Int64) -> URL {
        specDraftsDirectory(projectId: projectId).appending(path: "\(taskId).md")
    }

    public var attachmentsDirectory: URL {
        root.appending(path: "attachments", directoryHint: .isDirectory)
    }

    public func attachment(_ id: UUID, fileExtension: String) -> URL {
        attachmentsDirectory.appending(path: "\(id.uuidString.lowercased()).\(fileExtension)")
    }

    public var debugLogsDirectory: URL {
        root.appending(path: "debug-logs", directoryHint: .isDirectory)
    }

    public func pendingWorkspaceDirectory(_ name: String) -> URL {
        root.appending(path: "workspaces/\(Slug.make(name))", directoryHint: .isDirectory)
    }
}
