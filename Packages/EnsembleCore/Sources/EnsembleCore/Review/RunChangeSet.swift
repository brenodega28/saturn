import Foundation

public struct BranchChanges: Sendable, Hashable, Identifiable {
    public var agent: Agent
    public var branch: String
    public var base: String?
    public var mergeBase: String?
    public var files: [FileDiff]
    public var readsWorkingTree: Bool
    public var error: String?

    public init(
        agent: Agent, branch: String, base: String?, mergeBase: String? = nil, files: [FileDiff] = [],
        readsWorkingTree: Bool = false, error: String? = nil
    ) {
        self.agent = agent
        self.branch = branch
        self.base = base
        self.mergeBase = mergeBase
        self.files = files
        self.readsWorkingTree = readsWorkingTree
        self.error = error
    }

    public var id: String { branch }
    public var uncommittedFileCount: Int { files.count { $0.hasUncommittedChanges } }
}

public struct FileOverlap: Sendable, Hashable, Identifiable {
    public var path: String
    public var branches: [String]

    public init(path: String, branches: [String]) {
        self.path = path
        self.branches = branches
    }

    public var id: String { path }
}

public struct MergeConflict: Sendable, Hashable, Identifiable, Codable {
    public var branch: String
    public var other: String
    public var otherIsBase: Bool
    public var paths: [String]

    public init(branch: String, other: String, otherIsBase: Bool, paths: [String]) {
        self.branch = branch
        self.other = other
        self.otherIsBase = otherIsBase
        self.paths = paths
    }

    public var id: String { "\(branch)|\(other)" }
}

public struct BranchFileDiff: Sendable, Hashable, Identifiable {
    public var branch: String
    public var agentId: Int64?
    public var agentName: String
    public var agentRole: String
    public var diff: FileDiff

    public var id: String { "\(branch)|\(diff.path)" }
}

public struct ChangedPath: Sendable, Hashable, Identifiable {
    public var path: String
    public var diffs: [BranchFileDiff]
    public var isConflicted: Bool

    public var id: String { path }
    public var isOverlapping: Bool { Set(diffs.map(\.branch)).count > 1 }
    public var isGenerated: Bool { diffs.allSatisfy(\.diff.isGenerated) }
    public var hasUncommittedChanges: Bool { diffs.contains { $0.diff.hasUncommittedChanges } }
    public var additions: Int { diffs.reduce(0) { $0 + $1.diff.additions } }
    public var deletions: Int { diffs.reduce(0) { $0 + $1.diff.deletions } }
    public var agentIds: [Int64] { diffs.compactMap(\.agentId) }

    public var fingerprint: String {
        let joined = diffs.sorted { $0.branch < $1.branch }.map { "\($0.branch)\n\($0.diff.patch)" }.joined(separator: "\n\u{0}\n")
        return Self.fnv1a(joined)
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

public struct RunChangeSet: Sendable, Hashable {
    public var runId: Int64
    public var branches: [BranchChanges]
    public var overlaps: [FileOverlap]
    public var conflicts: [MergeConflict]
    public var conflictCheckError: String?

    public init(
        runId: Int64, branches: [BranchChanges] = [], overlaps: [FileOverlap] = [], conflicts: [MergeConflict] = [],
        conflictCheckError: String? = nil
    ) {
        self.runId = runId
        self.branches = branches
        self.overlaps = overlaps
        self.conflicts = conflicts
        self.conflictCheckError = conflictCheckError
    }

    public var conflictingPaths: Set<String> { Set(conflicts.flatMap(\.paths)) }

    public var paths: [ChangedPath] {
        var grouped: [String: [BranchFileDiff]] = [:]
        for branch in branches {
            for file in branch.files {
                let entry = BranchFileDiff(
                    branch: branch.branch, agentId: branch.agent.id, agentName: branch.agent.name,
                    agentRole: branch.agent.role, diff: file
                )
                grouped[file.path, default: []].append(entry)
            }
        }
        let conflicted = conflictingPaths
        return grouped.keys.sorted().map { path in
            let diffs = grouped[path] ?? []
            let isConflicted = diffs.contains { !$0.diff.touchedPaths.isDisjoint(with: conflicted) }
            return ChangedPath(path: path, diffs: diffs, isConflicted: isConflicted)
        }
    }

    public static func overlaps(in branches: [BranchChanges]) -> [FileOverlap] {
        var touching: [String: [String]] = [:]
        for branch in branches {
            for path in Set(branch.files.flatMap(\.touchedPaths)) {
                touching[path, default: []].append(branch.branch)
            }
        }
        return touching
            .filter { $0.value.count > 1 }
            .map { FileOverlap(path: $0.key, branches: $0.value.sorted()) }
            .sorted { $0.path < $1.path }
    }
}
