import Foundation

public struct RunChanges: Sendable {
    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public static func codingAgents(_ agents: [Agent], runId: Int64) -> [Agent] {
        var latestByBranch: [String: Agent] = [:]
        for agent in agents where agent.runId == runId && !agent.readOnly {
            guard let branch = agent.branch, !branch.isEmpty else { continue }
            if let existing = latestByBranch[branch], (existing.id ?? 0) > (agent.id ?? 0) { continue }
            latestByBranch[branch] = agent
        }
        return latestByBranch.values.sorted { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }
    }

    public func load(runId: Int64, agents: [Agent], repository: URL) async -> RunChangeSet {
        var branches: [BranchChanges] = []
        for agent in Self.codingAgents(agents, runId: runId) {
            branches.append(await branchChanges(for: agent, repository: repository))
        }
        var changeSet = RunChangeSet(runId: runId, branches: branches, overlaps: RunChangeSet.overlaps(in: branches))
        do {
            changeSet.conflicts = try await mergeConflicts(among: branches.filter { $0.error == nil }, repository: repository)
        } catch {
            changeSet.conflictCheckError = error.localizedDescription
        }
        return changeSet
    }

    public func branchChanges(for agent: Agent, repository: URL) async -> BranchChanges {
        let branch = agent.branch ?? ""
        var changes = BranchChanges(agent: agent, branch: branch, base: agent.baseBranch)
        do {
            let worktree = agent.worktreeURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let directory = worktree ?? repository
            let base = try await resolveBase(agent.baseBranch, repository: repository)
            changes.base = base
            guard try await git.hasCommit(branch, in: directory) || worktree != nil else {
                changes.error = "The branch \(branch) no longer exists."
                return changes
            }
            let tip = worktree == nil ? branch : "HEAD"
            let mergeBase = try await git.run(["merge-base", base, tip], in: directory).trimmed
            changes.mergeBase = mergeBase
            if worktree != nil {
                changes.readsWorkingTree = true
                changes.files = try await workingTreeDiff(since: mergeBase, in: directory)
            } else {
                changes.files = UnifiedDiffParser.parse(try await git.run(Self.diffArguments + [mergeBase, branch], in: directory))
            }
        } catch {
            changes.error = error.localizedDescription
        }
        return changes
    }

    public func mergeConflicts(among branches: [BranchChanges], repository: URL) async throws -> [MergeConflict] {
        var conflicts: [MergeConflict] = []
        for branch in branches {
            guard let base = branch.base else { continue }
            let paths = try await conflictingPaths(base, branch.branch, repository: repository)
            if !paths.isEmpty {
                conflicts.append(MergeConflict(branch: branch.branch, other: base, otherIsBase: true, paths: paths))
            }
        }
        for (index, branch) in branches.enumerated() {
            for other in branches.dropFirst(index + 1) {
                let paths = try await conflictingPaths(branch.branch, other.branch, repository: repository)
                if !paths.isEmpty {
                    conflicts.append(MergeConflict(branch: branch.branch, other: other.branch, otherIsBase: false, paths: paths))
                }
            }
        }
        return conflicts
    }

    public func conflictingPaths(_ ours: String, _ theirs: String, repository: URL) async throws -> [String] {
        let arguments = ["merge-tree", "--write-tree", "--name-only", "--no-messages", ours, theirs]
        let result = try await git.execute(arguments, in: repository)
        switch result.exitCode {
        case 0:
            return []
        case 1:
            var seen = Set<String>()
            return result.standardOutput
                .split(separator: "\n")
                .dropFirst()
                .map(String.init)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        default:
            throw CommandError(command: (["git"] + arguments).joined(separator: " "), result: result)
        }
    }

    static let diffArguments = [
        "-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M",
        "--src-prefix=a/", "--dst-prefix=b/",
    ]

    private func resolveBase(_ base: String?, repository: URL) async throws -> String {
        if let base, try await git.hasCommit(base, in: repository) { return base }
        if let current = try await git.currentBranch(in: repository) { return current }
        throw RunChangesError.unknownBase(base)
    }

    private func workingTreeDiff(since mergeBase: String, in worktree: URL) async throws -> [FileDiff] {
        var files = UnifiedDiffParser.parse(try await git.run(Self.diffArguments + [mergeBase], in: worktree))
        let status = Self.parseStatus(try await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: worktree))
        let dirty = Set(status.tracked)
        for index in files.indices where !files[index].touchedPaths.isDisjoint(with: dirty) {
            files[index].hasUncommittedChanges = true
        }
        for path in status.untracked where !files.contains(where: { $0.path == path }) {
            files.append(Self.untrackedFile(path, in: worktree))
        }
        return files.sorted { $0.path < $1.path }
    }

    static func parseStatus(_ output: String) -> (tracked: [String], untracked: [String]) {
        var tracked: [String] = []
        var untracked: [String] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            if code == "??" {
                untracked.append(path)
                continue
            }
            tracked.append(path)
            if code.contains("R") || code.contains("C"), let original = entries.next() {
                tracked.append(original)
            }
        }
        return (tracked, untracked)
    }

    static func untrackedFile(_ path: String, in worktree: URL) -> FileDiff {
        let data = (try? Data(contentsOf: worktree.appending(path: path))) ?? Data()
        var file = FileDiff(oldPath: nil, newPath: path, change: .added, newMode: "100644", hasUncommittedChanges: true)
        file.isGenerated = GeneratedFiles.isGenerated(path)
        var patch = ["diff --git a/\(path) b/\(path)", "new file mode 100644"]
        defer { file.patch = patch.joined(separator: "\n") }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
            file.isBinary = true
            patch.append("Binary files /dev/null and b/\(path) differ")
            return file
        }
        guard !text.isEmpty else { return file }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        var hunk = PatchHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count)
        hunk.lines = lines.enumerated().map { PatchLine(kind: .added, text: $0.element, oldLine: nil, newLine: $0.offset + 1) }
        if !endsWithNewline, let last = hunk.lines.indices.last { hunk.lines[last].missingNewlineAtEnd = true }
        file.hunks = [hunk]
        patch += ["--- /dev/null", "+++ b/\(path)", hunk.header] + lines.map { "+" + $0 }
        return file
    }
}

public enum RunChangesError: Error, LocalizedError, Equatable {
    case unknownBase(String?)

    public var errorDescription: String? {
        switch self {
        case .unknownBase(let base?): "The base branch \(base) can’t be found."
        case .unknownBase(nil): "This branch has no base to compare against."
        }
    }
}
