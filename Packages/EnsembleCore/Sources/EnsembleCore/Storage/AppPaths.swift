import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let standard = AppPaths(
        root: URL.applicationSupportDirectory.appending(path: "Ensemble", directoryHint: .isDirectory)
    )

    public var database: URL { root.appending(path: "ensemble.sqlite") }

    public func agentDirectory(_ agentID: Int64) -> URL {
        root.appending(path: "agents/\(agentID)", directoryHint: .isDirectory)
    }

    public func transcript(_ agentID: Int64) -> URL {
        agentDirectory(agentID).appending(path: "transcript.jsonl")
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
