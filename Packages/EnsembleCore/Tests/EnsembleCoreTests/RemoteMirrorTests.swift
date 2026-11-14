import Foundation
import Testing
@testable import EnsembleCore

@Suite struct RemoteMirrorTests {
    struct Fixture {
        let host: FakeSSHHost
        let repo: URL
        let mirror: RemoteMirror

        static func make() throws -> Fixture {
            let host = try FakeSSHHost()
            let repo = host.home.appending(path: "web app", directoryHint: .isDirectory)
            let local = host.root.appending(path: "local", directoryHint: .isDirectory)
            let client = SSHClient(destination: "devbox", executable: host.executable, controlDirectory: nil)
            let mirror = RemoteMirror(directory: local.appending(path: "files"), manifestFile: local.appending(path: "manifest.json"), repository: repo.path, client: client)
            return Fixture(host: host, repo: repo, mirror: mirror)
        }

        func put(_ path: String, _ text: String) throws {
            let file = repo.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func hostText(_ path: String) -> String? { try? String(contentsOf: repo.appending(path: path), encoding: .utf8) }
        func mirrorText(_ path: String) -> String? { try? String(contentsOf: mirror.directory.appending(path: path), encoding: .utf8) }

        func edit(_ path: String, _ text: String) throws {
            let file = mirror.directory.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test func pullsConfigSpecsReferencedDocsSkillsAndSmallTopLevelFilesOnly() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        try f.put(".ensemble/specs.yaml", "folder: design/specs\n")
        try f.put(".ensemble/docs.yaml", "docs:\n  - title: Guide\n    path: handbook/guide.md\n")
        try f.put("design/specs/login.md", "# Login\n")
        try f.put("handbook/guide.md", "guide\n")
        try f.put("handbook/other.md", "not referenced\n")
        try f.put(".claude/skills/review/SKILL.md", "skill\n")
        try f.put(".claude/settings.json", "{}\n")
        try f.put(".claude/worktrees/big.txt", "nope\n")
        try f.put("AGENTS.md", "rules\n")
        try f.put("package.json", "{\"scripts\":{}}\n")
        try f.put("src/app.ts", "code\n")
        try f.put("huge.log", String(repeating: "x", count: RemoteMirror.maximumTopLevelFileSize + 1))

        try await f.mirror.pull()

        let files = Set(RemoteMirror.hashes(in: f.mirror.directory).keys)
        #expect(files == [
            ".ensemble/specs.yaml", ".ensemble/docs.yaml", "design/specs/login.md", "handbook/guide.md",
            ".claude/skills/review/SKILL.md", ".claude/settings.json", "AGENTS.md", "package.json",
        ])
        #expect(try f.mirror.pendingChanges().isEmpty)
        #expect(ProjectConfigLoader.loadSpecs(repository: f.mirror.directory).folder == "design/specs")
    }

    @Test func pushesEditsAdditionsAndDeletionsBackToTheHost() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        try f.put(".ensemble/project.yaml", "branch_prefix: crew\n")
        try f.put(".ensemble/workflows/old.yaml", "id: old\n")
        try await f.mirror.pull()

        try f.edit(".ensemble/project.yaml", "branch_prefix: agents\n")
        try f.edit(".ensemble/workflows/it's new.yaml", "name: 'quoted' $HOME `id`\n")
        try FileManager.default.removeItem(at: f.mirror.directory.appending(path: ".ensemble/workflows/old.yaml"))
        try f.edit("AGENTS.md", "")

        let pushed = try await f.mirror.push()

        #expect(pushed.written == [".ensemble/project.yaml", ".ensemble/workflows/it's new.yaml", "AGENTS.md"])
        #expect(pushed.deleted == [".ensemble/workflows/old.yaml"])
        #expect(f.hostText(".ensemble/project.yaml") == "branch_prefix: agents\n")
        #expect(f.hostText(".ensemble/workflows/it's new.yaml") == "name: 'quoted' $HOME `id`\n")
        #expect(f.hostText("AGENTS.md") == "")
        #expect(f.hostText(".ensemble/workflows/old.yaml") == nil)
        #expect(try f.mirror.pendingChanges().isEmpty)
        #expect(try await f.mirror.push().isEmpty)
    }

    @Test func roundTripsBinaryFiles() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        try FileManager.default.createDirectory(at: f.repo, withIntermediateDirectories: true)
        try await f.mirror.pull()
        let bytes = Data((0..<4096).map { UInt8($0 % 256) })
        try FileManager.default.createDirectory(at: f.mirror.directory.appending(path: ".ensemble/docs"), withIntermediateDirectories: true)
        try bytes.write(to: f.mirror.directory.appending(path: ".ensemble/docs/spec.pdf"))

        try await f.mirror.push()

        #expect(try Data(contentsOf: f.repo.appending(path: ".ensemble/docs/spec.pdf")) == bytes)
    }

    @Test func refusesToOverwriteFilesThatChangedOnTheHost() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        try f.put(".ensemble/project.yaml", "branch_prefix: crew\n")
        try await f.mirror.pull()

        try f.put(".ensemble/project.yaml", "branch_prefix: from-git-pull\n")
        try f.edit(".ensemble/project.yaml", "branch_prefix: mine\n")
        try f.edit(".ensemble/new.yaml", "fresh\n")
        try f.put(".ensemble/new.yaml", "also created on the host\n")

        await #expect(throws: RemoteMirrorConflict(paths: [".ensemble/new.yaml", ".ensemble/project.yaml"])) { try await f.mirror.push() }
        #expect(f.hostText(".ensemble/project.yaml") == "branch_prefix: from-git-pull\n")

        try await f.mirror.pull()
        #expect(f.mirrorText(".ensemble/project.yaml") == "branch_prefix: from-git-pull\n")
        #expect(try f.mirror.pendingChanges().isEmpty)
    }

    @Test func pullingAnEmptyOrMissingRepository() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        try FileManager.default.createDirectory(at: f.repo, withIntermediateDirectories: true)
        try await f.mirror.pull()
        #expect(RemoteMirror.hashes(in: f.mirror.directory).isEmpty)

        try FileManager.default.removeItem(at: f.repo)
        await #expect(throws: RemoteFolderError.notFound(f.repo.path)) { try await f.mirror.pull() }
    }
}
