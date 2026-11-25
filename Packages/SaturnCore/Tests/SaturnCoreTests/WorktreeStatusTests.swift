import Foundation
import Testing
@testable import SaturnCore

@Suite struct WorktreeStatusTests {
    @Test func reportsCommitsAheadAndChangedFiles() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let worktree = try await repo.manager.create(agent: "dev", slug: "work")

        try "hello\nworld\n".write(to: worktree.path.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: worktree.path.appending(path: "added.txt"), atomically: true, encoding: .utf8)
        try await repo.git.run(["add", "added.txt"], in: worktree.path)
        try await repo.git.run(["commit", "-m", "Add file"], in: worktree.path)
        try "draft\n".write(to: worktree.path.appending(path: "notes.md"), atomically: true, encoding: .utf8)

        let status = try await repo.git.status(of: worktree.path, base: "main")

        #expect(status.branch == "crew/dev/work")
        #expect(status.base == "main")
        #expect(status.commitsAhead == 1)
        #expect(status.changedFiles.map(\.path) == ["README.md", "added.txt", "notes.md"])
        #expect(status.changedFiles.map(\.change) == [.modified, .added, .untracked])
        #expect(status.changedFiles.map(\.isCommitted) == [false, true, false])

        let readmeDiff = try await repo.git.diff(of: "README.md", in: worktree.path, base: "main")
        #expect(readmeDiff.contains("+world"))
        let untrackedDiff = try await repo.git.diff(of: "notes.md", in: worktree.path, base: "main")
        #expect(untrackedDiff.hasPrefix("+draft"))
    }

    @Test func toleratesUnknownBase() async throws {
        let repo = try await TestRepository.make()
        defer { repo.delete() }

        let status = try await repo.git.status(of: repo.root, base: "does-not-exist")

        #expect(status.base == nil)
        #expect(status.commitsAhead == 0)
        #expect(status.changedFiles.isEmpty)
    }

    @Test func parsesPorcelainRenamesAndDeletes() {
        let files = GitClient.parsePorcelainStatus(" D gone.txt\nR  old.txt -> new.txt\nA  added.swift\n?? scratch\n M edited.md\n")
        #expect(files.map(\.path) == ["gone.txt", "new.txt", "added.swift", "scratch", "edited.md"])
        #expect(files.map(\.change) == [.deleted, .renamed, .added, .untracked, .modified])
    }
}
