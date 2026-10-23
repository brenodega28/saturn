import Foundation
@testable import EnsembleCore

struct TestRepository {
    let root: URL
    let git: GitClient

    static func make(withInitialCommit: Bool = true) async throws -> TestRepository {
        let locator = ToolLocator()
        guard let gitPath = locator.locate("git") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "git not installed"])
        }
        var environment = locator.environment()
        environment["GIT_AUTHOR_NAME"] = "Ensemble Tests"
        environment["GIT_AUTHOR_EMAIL"] = "tests@ensemble.invalid"
        environment["GIT_COMMITTER_NAME"] = "Ensemble Tests"
        environment["GIT_COMMITTER_EMAIL"] = "tests@ensemble.invalid"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        let git = GitClient(executable: gitPath, runner: CommandRunner(environment: environment))

        let root = FileManager.default.temporaryDirectory
            .appending(path: "ensemble-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git.run(["init", "-b", "main"], in: root)
        if withInitialCommit {
            try "hello\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try await git.run(["add", "README.md"], in: root)
            try await git.run(["commit", "-m", "Initial commit"], in: root)
        }
        return TestRepository(root: root, git: git)
    }

    var manager: WorktreeManager { WorktreeManager(repository: root, git: git) }

    func status() async throws -> String {
        try await git.run(["status", "--porcelain", "--untracked-files=all"], in: root)
    }

    func branches() async throws -> [String] {
        try await git.run(["branch", "--format=%(refname:short)"], in: root)
            .split(separator: "\n").map(String.init)
    }

    func delete() {
        try? FileManager.default.removeItem(at: root)
    }
}
