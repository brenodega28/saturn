import Foundation
import Testing
@testable import EnsembleCore

@Suite struct WorktreeManagerTests {
    @Test func namesBranchesAndPathsAfterAgentAndSlug() throws {
        let manager = WorktreeManager(
            repository: URL(fileURLWithPath: "/tmp/repo"),
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), runner: CommandRunner())
        )

        #expect(try manager.branchName(agent: "Django Dev 1", slug: "Refund model & API") == "crew/django-dev-1/refund-model-api")
        #expect(try manager.path(forAgent: "Django Dev 1").path == "/tmp/repo/.crew/django-dev-1")
        #expect(throws: WorktreeError.invalidName("!!!")) { try manager.branchName(agent: "!!!", slug: "x") }
    }

    @Test func createsListsAndRemovesThreeWorktrees() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let manager = repo.manager

        for index in 1...3 {
            let worktree = try await manager.create(agent: "Agent \(index)", slug: "task \(index)")
            #expect(worktree.branch == "crew/agent-\(index)/task-\(index)")
            #expect(worktree.agent == "agent-\(index)")
            #expect(FileManager.default.fileExists(atPath: worktree.path.appending(path: "README.md").path))
        }

        let listed = try await manager.list()
        #expect(listed.map(\.agent) == ["agent-1", "agent-2", "agent-3"])
        #expect(try await repo.status().isEmpty)

        for worktree in listed {
            try await manager.remove(worktree, force: false, deleteBranch: true)
        }

        #expect(try await manager.list().isEmpty)
        #expect(try await repo.branches() == ["main"])
    }

    @Test func excludesCrewDirectoryOnce() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }

        try await repo.manager.create(agent: "a", slug: "one")
        try await repo.manager.create(agent: "b", slug: "two")

        let exclude = try String(contentsOf: repo.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").filter { $0 == "/.crew/" }.count == 1)
        #expect(try await repo.status().isEmpty)
    }

    @Test func refusesDuplicateAgent() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }

        try await repo.manager.create(agent: "dev", slug: "one")
        await #expect(throws: WorktreeError.alreadyExists(agent: "dev")) {
            try await repo.manager.create(agent: "dev", slug: "two")
        }
    }

    @Test func keepsDirtyWorktreeUnlessForced() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }

        let worktree = try await repo.manager.create(agent: "dev", slug: "wip")
        try "change\n".write(to: worktree.path.appending(path: "README.md"), atomically: true, encoding: .utf8)

        await #expect(throws: CommandError.self) {
            try await repo.manager.remove(worktree, force: false, deleteBranch: true)
        }
        #expect(try await repo.manager.list().count == 1)

        try await repo.manager.remove(worktree, force: true, deleteBranch: false)
        #expect(try await repo.manager.list().isEmpty)
        #expect(try await repo.branches().contains("crew/dev/wip"))
    }

    @Test func ignoresWorktreesOutsideCrew() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let outside = repo.root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }

        try await repo.git.run(["worktree", "add", "-b", "elsewhere", outside.path], in: repo.root)

        #expect(try await repo.manager.list().isEmpty)
    }

    @Test func recoversMissingAndOrphanedWorktrees() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let manager = repo.manager

        let kept = try await manager.create(agent: "kept", slug: "one")
        let lost = try await manager.create(agent: "lost", slug: "two")
        try FileManager.default.removeItem(at: lost.path)
        let stray = manager.crewDirectory.appending(path: "stray", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let recovery = try await manager.recover()

        #expect(recovery.worktrees.map(\.agent) == [kept.agent])
        #expect(recovery.pruned.map(\.agent) == ["lost"])
        #expect(recovery.orphanedDirectories.map(\.lastPathComponent) == ["stray"])
        #expect(!recovery.isClean)

        try await manager.deleteOrphanedDirectory(stray)
        let second = try await manager.recover()
        #expect(second.isClean)
        #expect(try await repo.branches().contains("crew/lost/two"))
    }

    @Test func refusesToDeleteOutsideCrew() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }

        await #expect(throws: WorktreeError.outsideCrewDirectory(repo.root)) {
            try await repo.manager.deleteOrphanedDirectory(repo.root)
        }
        await #expect(throws: WorktreeError.self) {
            try await repo.manager.deleteOrphanedDirectory(repo.manager.crewDirectory)
        }
    }

    @Test func refusesRepositoryWithoutCommits() async throws {
        let repo = try await TestRepository.make(withInitialCommit: false)
        defer { repo.delete() }

        await #expect(throws: WorktreeError.noCommits) {
            try await repo.manager.create(agent: "dev", slug: "one")
        }
        #expect(try await repo.manager.list().isEmpty)
    }

    @Test func parsesPorcelainOutput() {
        let output = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /repo/.crew/dev
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/crew/dev/task
        locked

        worktree /repo/.crew/gone
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """

        let worktrees = Worktree.parsePorcelain(output)

        #expect(worktrees.count == 3)
        #expect(worktrees[1].branch == "crew/dev/task")
        #expect(worktrees[1].isLocked)
        #expect(worktrees[2].branch == nil)
        #expect(worktrees[2].isPrunable)
    }
}
