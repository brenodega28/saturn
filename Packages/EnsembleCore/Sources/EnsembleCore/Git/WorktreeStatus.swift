import Foundation

public struct ChangedFile: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable, Hashable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case renamed = "R"
        case untracked = "?"
    }

    public let path: String
    public let change: Change
    public let isCommitted: Bool

    public var id: String { path }
}

public struct WorktreeStatus: Sendable, Hashable {
    public let branch: String?
    public let base: String?
    public let commitsAhead: Int
    public let changedFiles: [ChangedFile]
}

extension GitClient {
    public func status(of worktree: URL, base: String?) async throws -> WorktreeStatus {
        let branch = try await currentBranch(in: worktree)
        let resolvedBase = try await base.asyncFilter { try await hasCommit($0, in: worktree) }

        var committed: [ChangedFile] = []
        var ahead = 0
        if let resolvedBase {
            ahead = Int(try await run(["rev-list", "--count", "\(resolvedBase)..HEAD"], in: worktree).trimmed) ?? 0
            committed = Self.parseNameStatus(
                try await run(["diff", "--name-status", "--no-renames", "\(resolvedBase)...HEAD"], in: worktree)
            )
        }
        let working = Self.parsePorcelainStatus(
            try await run(["status", "--porcelain=v1", "--untracked-files=all"], in: worktree)
        )

        var byPath: [String: ChangedFile] = [:]
        for file in committed { byPath[file.path] = file }
        for file in working { byPath[file.path] = file }
        return WorktreeStatus(
            branch: branch,
            base: resolvedBase,
            commitsAhead: ahead,
            changedFiles: byPath.values.sorted { $0.path < $1.path }
        )
    }

    public func diff(of path: String, in worktree: URL, base: String?) async throws -> String {
        let tracked = try await run(["diff", base ?? "HEAD", "--", path], in: worktree)
        if !tracked.isEmpty { return tracked }
        let file = worktree.appending(path: path)
        let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
    }

    static func parseNameStatus(_ output: String) -> [ChangedFile] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let letter = parts[0].first else { return nil }
            return ChangedFile(path: parts[1], change: ChangedFile.Change(rawValue: String(letter)) ?? .modified, isCommitted: true)
        }
    }

    static func parsePorcelainStatus(_ output: String) -> [ChangedFile] {
        output.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let code = line.prefix(2)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            let change: ChangedFile.Change = switch code {
            case "??": .untracked
            case _ where code.contains("D"): .deleted
            case _ where code.contains("A"): .added
            case _ where code.contains("R"): .renamed
            default: .modified
            }
            return ChangedFile(path: path, change: change, isCommitted: false)
        }
    }
}

extension Optional {
    func asyncFilter(_ predicate: (Wrapped) async throws -> Bool) async rethrows -> Wrapped? {
        guard let value = self, try await predicate(value) else { return nil }
        return value
    }
}
