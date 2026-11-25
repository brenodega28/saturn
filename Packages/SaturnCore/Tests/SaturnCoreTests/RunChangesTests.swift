import Foundation
import Testing
@testable import SaturnCore

@Suite struct RunChangesTests {
    static func agent(_ id: Int64, name: String, runId: Int64 = 1, worktree: Worktree? = nil, branch: String? = nil, readOnly: Bool = false) -> Agent {
        Agent(
            id: id, projectId: 1, runId: runId, role: "claude-code", name: name, worktreePath: worktree?.path.path,
            branch: branch ?? worktree?.branch, status: .idle, baseBranch: "main", readOnly: readOnly,
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)), updatedAt: .now
        )
    }

    static func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func commit(_ message: String, in directory: URL, git: GitClient) async throws {
        try await git.run(["add", "-A"], in: directory)
        try await git.run(["commit", "-m", message], in: directory)
    }

    @Test func collectsBranchDiffsWithUncommittedAndUntrackedFiles() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let worktree = try await repo.manager.create(agent: "dev-1", slug: "refunds")
        try Self.write("hello\nworld\n", to: "README.md", in: worktree.path)
        try Self.write("{}\n", to: "package-lock.json", in: worktree.path)
        try Self.write("def refund():\n    pass\n", to: "orders/refunds.py", in: worktree.path)
        try await Self.commit("Add refunds", in: worktree.path, git: repo.git)
        try Self.write("def refund():\n    return 1\n", to: "orders/refunds.py", in: worktree.path)
        try Self.write("draft", to: "notes/plan.md", in: worktree.path)

        let changes = await RunChanges(git: repo.git).branchChanges(for: Self.agent(1, name: "Dev 1", worktree: worktree), repository: repo.root)

        #expect(changes.error == nil)
        #expect(changes.branch == "crew/dev-1/refunds")
        #expect(changes.base == "main")
        #expect(changes.readsWorkingTree)
        #expect(changes.files.map(\.path) == ["README.md", "notes/plan.md", "orders/refunds.py", "package-lock.json"])
        #expect(changes.files.map(\.hasUncommittedChanges) == [false, true, true, false])
        #expect(changes.files.map(\.change) == [.modified, .added, .added, .added])
        #expect(changes.files.map(\.isGenerated) == [false, false, false, true])
        #expect(changes.uncommittedFileCount == 2)

        let untracked = changes.files[1]
        #expect(untracked.hunks.first?.lines.map(\.text) == ["draft"])
        #expect(untracked.hunks.first?.lines.first?.missingNewlineAtEnd == true)
        let refunds = changes.files[2]
        #expect(refunds.hunks.first?.lines.map(\.text) == ["def refund():", "    return 1"])
    }

    @Test func readsBranchWhenWorktreeIsGone() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let worktree = try await repo.manager.create(agent: "dev-1", slug: "gone")
        try Self.write("bye\n", to: "README.md", in: worktree.path)
        try await Self.commit("Change readme", in: worktree.path, git: repo.git)
        try await repo.manager.remove(worktree, force: true, deleteBranch: false)

        let changes = await RunChanges(git: repo.git).branchChanges(for: Self.agent(1, name: "Dev 1", worktree: worktree), repository: repo.root)

        #expect(changes.error == nil)
        #expect(!changes.readsWorkingTree)
        #expect(changes.files.map(\.path) == ["README.md"])
        #expect(changes.files.first?.hunks.first?.lines.map(\.kind) == [.removed, .added])
    }

    @Test func reportsMissingBranch() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let changes = await RunChanges(git: repo.git).branchChanges(for: Self.agent(1, name: "Dev 1", branch: "crew/none/missing"), repository: repo.root)
        #expect(changes.error != nil)
        #expect(changes.files.isEmpty)
    }

    @Test func detectsOverlapsAndRealMergeConflicts() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        try Self.write("a\nb\nc\nd\ne\nf\ng\nh\n", to: "shared.py", in: repo.root)
        try await Self.commit("Add shared", in: repo.root, git: repo.git)

        let one = try await repo.manager.create(agent: "dev-1", slug: "one")
        let two = try await repo.manager.create(agent: "dev-2", slug: "two")
        let three = try await repo.manager.create(agent: "dev-3", slug: "three")
        try Self.write("A\nb\nc\nd\ne\nf\ng\nh\n", to: "shared.py", in: one.path)
        try await Self.commit("One edits the top", in: one.path, git: repo.git)
        try Self.write("A!\nb\nc\nd\ne\nf\ng\nH\n", to: "shared.py", in: two.path)
        try await Self.commit("Two edits top and bottom", in: two.path, git: repo.git)
        try Self.write("a\nb\nc\nd\ne\nf\ng\nh!\n", to: "shared.py", in: three.path)
        try Self.write("x\n", to: "only-three.txt", in: three.path)
        try await Self.commit("Three edits the bottom", in: three.path, git: repo.git)

        let agents = [
            Self.agent(1, name: "Dev 1", worktree: one),
            Self.agent(2, name: "Dev 2", worktree: two),
            Self.agent(3, name: "Dev 3", worktree: three),
            Self.agent(4, name: "Reviewer", worktree: three, readOnly: true),
            Self.agent(5, name: "Other run", runId: 2, worktree: one),
        ]
        let changeSet = await RunChanges(git: repo.git).load(runId: 1, agents: agents, repository: repo.root)

        #expect(changeSet.branches.map(\.agent.name) == ["Dev 1", "Dev 2", "Dev 3"])
        #expect(changeSet.conflictCheckError == nil)
        #expect(changeSet.overlaps == [FileOverlap(path: "shared.py", branches: ["crew/dev-1/one", "crew/dev-2/two", "crew/dev-3/three"])])
        #expect(changeSet.conflicts.map(\.id) == ["crew/dev-1/one|crew/dev-2/two", "crew/dev-2/two|crew/dev-3/three"])
        #expect(changeSet.conflicts.allSatisfy { $0.paths == ["shared.py"] && !$0.otherIsBase })
        #expect(changeSet.conflictingPaths == ["shared.py"])

        let paths = changeSet.paths
        #expect(paths.map(\.path) == ["only-three.txt", "shared.py"])
        #expect(paths.map(\.isConflicted) == [false, true])
        #expect(paths.map(\.isOverlapping) == [false, true])
        #expect(paths[1].diffs.map(\.agentName) == ["Dev 1", "Dev 2", "Dev 3"])
    }

    @Test func detectsConflictWithAdvancedBase() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let worktree = try await repo.manager.create(agent: "dev-1", slug: "late")
        try Self.write("branch\n", to: "README.md", in: worktree.path)
        try await Self.commit("Branch edit", in: worktree.path, git: repo.git)
        try Self.write("main moved\n", to: "README.md", in: repo.root)
        try await Self.commit("Main edit", in: repo.root, git: repo.git)

        let changeSet = await RunChanges(git: repo.git).load(runId: 1, agents: [Self.agent(1, name: "Dev 1", worktree: worktree)], repository: repo.root)

        #expect(changeSet.overlaps.isEmpty)
        #expect(changeSet.conflicts == [MergeConflict(branch: "crew/dev-1/late", other: "main", otherIsBase: true, paths: ["README.md"])])
        #expect(changeSet.branches.first?.files.first?.hunks.first?.lines.last?.text == "branch")
    }

    @Test func cleanBranchesHaveNoConflicts() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let one = try await repo.manager.create(agent: "dev-1", slug: "a")
        let two = try await repo.manager.create(agent: "dev-2", slug: "b")
        try Self.write("1\n", to: "a.txt", in: one.path)
        try await Self.commit("a", in: one.path, git: repo.git)
        try Self.write("2\n", to: "b.txt", in: two.path)
        try await Self.commit("b", in: two.path, git: repo.git)

        let changeSet = await RunChanges(git: repo.git).load(
            runId: 1, agents: [Self.agent(1, name: "Dev 1", worktree: one), Self.agent(2, name: "Dev 2", worktree: two)], repository: repo.root
        )
        #expect(changeSet.conflicts.isEmpty)
        #expect(changeSet.overlaps.isEmpty)
        #expect(changeSet.paths.map(\.path) == ["a.txt", "b.txt"])
    }

    @Test func parsesNulSeparatedStatus() {
        let status = RunChanges.parseStatus(" M edited.swift\0R  new.swift\0old.swift\0?? scratch/notes.md\0A  added.txt\0")
        #expect(status.tracked == ["edited.swift", "new.swift", "old.swift", "added.txt"])
        #expect(status.untracked == ["scratch/notes.md"])
    }

    @Test func fingerprintFollowsPatchContent() {
        let file = FileDiff(oldPath: "a", newPath: "a", change: .modified, patch: "diff one")
        let entry = BranchFileDiff(branch: "b", agentId: 1, agentName: "Dev", agentRole: "claude-code", diff: file)
        var changed = entry
        changed.diff.patch = "diff two"
        #expect(ChangedPath(path: "a", diffs: [entry], isConflicted: false).fingerprint == ChangedPath(path: "a", diffs: [entry], isConflicted: false).fingerprint)
        #expect(ChangedPath(path: "a", diffs: [entry], isConflicted: false).fingerprint != ChangedPath(path: "a", diffs: [changed], isConflicted: false).fingerprint)
    }
}
