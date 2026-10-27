import Foundation

public struct ProtectedChange: Sendable, Hashable {
    public let path: String
    public let deleted: Bool
    public let line: Int
    public let pattern: String
}

enum ProtectedChanges {
    static func mergeBase(of base: String, in worktree: URL, git: GitClient) async -> String {
        (try? await git.run(["merge-base", base, "HEAD"], in: worktree))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? base
    }

    static func find(in worktree: URL, base: String, protectedPaths: [String], git: GitClient) async -> [ProtectedChange] {
        guard !protectedPaths.isEmpty else { return [] }
        let start = await mergeBase(of: base, in: worktree, git: git)
        guard let output = try? await git.run(["diff", "--name-status", "-M", start], in: worktree) else { return [] }
        var changes: [ProtectedChange] = []
        for row in output.split(separator: "\n") {
            let columns = row.split(separator: "\t").map(String.init)
            guard columns.count >= 2, let status = columns[0].first, status != "A" else { continue }
            let path = columns[1]
            guard let pattern = protectedPaths.first(where: { PathGlob($0).matches(path) }) else { continue }
            let deleted = status == "D"
            let line = deleted ? 1 : await firstChangedLine(of: path, since: start, in: worktree, git: git)
            changes.append(ProtectedChange(path: path, deleted: deleted, line: line, pattern: pattern))
        }
        return changes
    }

    static func firstChangedLine(of path: String, since start: String, in worktree: URL, git: GitClient) async -> Int {
        guard let diff = try? await git.run(["diff", "-U0", "-M", start, "--", path], in: worktree) else { return 1 }
        for line in diff.split(separator: "\n") where line.hasPrefix("@@") {
            let parts = line.split(separator: " ")
            guard parts.count > 2, parts[2].hasPrefix("+") else { continue }
            let number = parts[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 1
            return max(1, number)
        }
        return 1
    }

    static func reproductionCommit(prefix: String, since start: String, in worktree: URL, git: GitClient) async -> String? {
        guard let log = try? await git.run(["log", "--reverse", "--format=%H%x09%s", "\(start)..HEAD"], in: worktree) else { return nil }
        for row in log.split(separator: "\n") {
            let columns = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard columns.count == 2, columns[1].lowercased().hasPrefix(prefix.lowercased()) else { continue }
            return columns[0]
        }
        return nil
    }
}
