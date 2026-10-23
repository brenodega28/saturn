import Foundation

public struct Worktree: Sendable, Hashable, Identifiable {
    public let path: URL
    public let head: String?
    public let branch: String?
    public let isLocked: Bool
    public let isPrunable: Bool

    public var id: String { path.path }

    public var agent: String { path.lastPathComponent }

    public init(path: URL, head: String?, branch: String?, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    static func parsePorcelain(_ output: String) -> [Worktree] {
        output
            .components(separatedBy: "\n\n")
            .compactMap { block -> Worktree? in
                var path: URL?
                var head: String?
                var branch: String?
                var isLocked = false
                var isPrunable = false
                for line in block.split(separator: "\n") {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    let value = parts.count > 1 ? parts[1] : ""
                    switch parts.first {
                    case "worktree": path = URL(fileURLWithPath: value, isDirectory: true)
                    case "HEAD": head = value
                    case "branch": branch = value.replacingOccurrences(of: "refs/heads/", with: "")
                    case "locked": isLocked = true
                    case "prunable": isPrunable = true
                    default: break
                    }
                }
                return path.map { Worktree(path: $0, head: head, branch: branch, isLocked: isLocked, isPrunable: isPrunable) }
            }
    }
}

public struct WorktreeRecovery: Sendable, Equatable {
    public let worktrees: [Worktree]
    public let pruned: [Worktree]
    public let orphanedDirectories: [URL]

    public var isClean: Bool { pruned.isEmpty && orphanedDirectories.isEmpty }
}
