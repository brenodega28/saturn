import Foundation
import Testing
@testable import EnsembleCore

@Suite struct RemoteWorktreeTests {
    struct Remote {
        let host: FakeSSHHost
        let repo: TestRepository
        let root: URL
        let client: SSHClient

        static func make(folder: String = "shop front") async throws -> Remote {
            let host = try FakeSSHHost()
            let local = try await TestRepository.make()
            let root = host.home.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: local.root, to: root)
            let client = SSHClient(destination: "devbox", executable: host.executable, controlDirectory: nil)
            let resolved = try await RemoteHost(client: client).repositoryRoot(containing: root.path)
            return Remote(host: host, repo: TestRepository(root: root, git: local.git), root: URL(fileURLWithPath: resolved, isDirectory: true), client: client)
        }

        var git: GitClient { GitClient(ssh: client) }
        var fileSystem: SSHFileSystem { SSHFileSystem(client: client) }
        var manager: WorktreeManager { WorktreeManager(repository: root, git: git, fileSystem: fileSystem) }

        func remove() { host.remove() }
    }

    @Test func runsGitOnTheHostInTheRightFolder() async throws {
        let remote = try await Remote.make()
        defer { remote.remove() }

        #expect(remote.git.isRemote)
        #expect(try await remote.git.currentBranch(in: remote.root) == "main")
        #expect(try await remote.git.repositoryRoot(containing: remote.root).path == remote.root.path)
        #expect(try await remote.git.hasCommit("HEAD", in: remote.root))
        await #expect(throws: CommandError.self) { try await remote.git.run(["rev-parse", "--verify", "nope"], in: remote.root) }
    }

    @Test func createsListsAndRemovesWorktreesOnTheHost() async throws {
        let remote = try await Remote.make()
        defer { remote.remove() }
        let manager = remote.manager
        #expect(manager.crewDirectory.path == remote.root.path + "/.crew")

        let worktree = try await manager.create(agent: "Builder 1", slug: "refunds")
        #expect(worktree.agent == "builder-1")
        #expect(worktree.branch == "crew/builder-1/refunds")
        #expect(worktree.path.path == remote.root.appending(path: ".crew/builder-1").path)
        #expect(FileManager.default.fileExists(atPath: worktree.path.appending(path: "README.md").path))
        await #expect(throws: WorktreeError.alreadyExists(agent: "builder-1")) { try await manager.create(agent: "builder-1", slug: "again") }

        try await manager.ensureExcluded()
        let exclude = try String(contentsOf: remote.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").filter { $0 == "/.crew/" }.count == 1)
        #expect(try await remote.repo.status().isEmpty)

        #expect(try await manager.list().map(\.agent) == ["builder-1"])
        try await manager.remove(worktree, force: false, deleteBranch: true)
        #expect(try await manager.list().isEmpty)
        #expect(!(try await remote.repo.branches()).contains("crew/builder-1/refunds"))
    }

    @Test func recoversPrunedAndOrphanedWorktreesAndRestoresThem() async throws {
        let remote = try await Remote.make()
        defer { remote.remove() }
        let manager = remote.manager
        let lost = try await manager.create(agent: "lost", slug: "two")
        try FileManager.default.removeItem(at: lost.path)
        try FileManager.default.createDirectory(at: manager.crewDirectory.appending(path: "stray"), withIntermediateDirectories: true)

        let recovery = try await manager.recover()
        #expect(recovery.pruned.map(\.agent) == ["lost"])
        #expect(recovery.worktrees.isEmpty)
        #expect(recovery.orphanedDirectories.map(\.lastPathComponent) == ["stray"])

        try await manager.deleteOrphanedDirectory(recovery.orphanedDirectories[0])
        #expect(!FileManager.default.fileExists(atPath: manager.crewDirectory.appending(path: "stray").path))
        await #expect(throws: WorktreeError.outsideCrewDirectory(remote.root)) { try await manager.deleteOrphanedDirectory(remote.root) }

        let restored = try await manager.restore(at: lost.path, branch: "crew/lost/two")
        #expect(restored.branch == "crew/lost/two")
        #expect(try await manager.list().map(\.agent) == ["lost"])
    }

    @Test func readsTheBranchPrefixFromTheHost() async throws {
        let remote = try await Remote.make()
        defer { remote.remove() }
        try remote.fileSystem.client.runCheckedSync("mkdir -p '\(remote.root.path)/.ensemble' && printf 'branch_prefix: agents/\\n' > '\(remote.root.path)/.ensemble/project.yaml'")

        let manager = await WorktreeManager.make(repository: remote.root, git: remote.git, fileSystem: remote.fileSystem)

        #expect(manager.branchPrefix == "agents")
        #expect(WorktreeManager(repository: remote.root, git: remote.git, fileSystem: remote.fileSystem).branchPrefix == "crew")
    }

    @Test func readsAndWritesFilesWithAwkwardContentOnTheHost() async throws {
        let remote = try await Remote.make()
        defer { remote.remove() }
        let file = remote.root.appending(path: "notes/it's here.txt")
        let text = "line 'one'\n$HOME `id` \\ end\n"

        try await remote.fileSystem.createDirectory(file.deletingLastPathComponent())
        try await remote.fileSystem.writeText(text, to: file)

        #expect(try await remote.fileSystem.readText(file) == text)
        #expect(try await remote.fileSystem.fileExists(file))
        #expect(try await remote.fileSystem.readText(remote.root.appending(path: "missing")) == nil)
        #expect(try await remote.fileSystem.subdirectories(of: remote.root).map(\.lastPathComponent) == ["notes"])
        #expect(try await remote.fileSystem.subdirectories(of: remote.root.appending(path: "missing")).isEmpty)
    }
}

@Suite struct SSHPathTests {
    @Test func normalizesWithoutLookingAtTheLocalDisk() {
        #expect(SSHFileSystem.normalize("/private/var/x/") == "/private/var/x")
        #expect(SSHFileSystem.normalize("/srv//shop/./a/../b") == "/srv/shop/b")
        #expect(SSHFileSystem.normalize("/") == "/")
        #expect(SSHFileSystem.normalize("/../..") == "/")
    }
}

extension SSHClient {
    func runCheckedSync(_ command: String) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: command)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

@Suite struct RemoteCodeWorkspaceTests {
    @Test func listsReadsAndSearchesFilesOnTheHost() async throws {
        let remote = try await RemoteWorktreeTests.Remote.make()
        defer { remote.remove() }
        let root = remote.repo.root
        try "let greeting = \"Hello\"\nprint(greeting)\n".write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try "Say HELLO to everyone\n".write(to: root.appending(path: "docs/it's.md"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: root.appending(path: "blob.bin"))
        try String(repeating: "x", count: CodeWorkspace.maxDocumentBytes + 1).write(to: root.appending(path: "big.txt"), atomically: true, encoding: .utf8)
        try await remote.repo.git.run(["add", "main.swift"], in: root)
        try await remote.repo.git.run(["commit", "-m", "main"], in: root)
        try FileManager.default.removeItem(at: root.appending(path: "README.md"))
        let workspace = CodeWorkspace(root: remote.root, baseBranch: nil, git: remote.git)

        let snapshot = try await workspace.snapshot()
        #expect(snapshot.files == ["big.txt", "blob.bin", "docs/it's.md", "main.swift"])
        #expect(snapshot.changes["docs/it's.md"]?.status == .added)

        #expect(await workspace.loadDocument("main.swift") == .text(lines: ["let greeting = \"Hello\"", "print(greeting)"]))
        #expect(await workspace.loadDocument("docs/it's.md") == .text(lines: ["Say HELLO to everyone"]))
        #expect(await workspace.loadDocument("blob.bin") == .binary)
        #expect(await workspace.loadDocument("big.txt") == .tooLarge(bytes: CodeWorkspace.maxDocumentBytes + 1))
        #expect(await workspace.loadDocument("nope.txt") == .missing)

        let hits = await workspace.search("hello", in: snapshot.files)
        #expect(hits.map(\.path) == ["docs/it's.md", "main.swift"])
        #expect(hits.first?.line == 1)
        #expect(hits.first?.matchStart == 4)
    }
}
