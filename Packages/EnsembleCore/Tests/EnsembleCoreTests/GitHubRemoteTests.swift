import Foundation
import Testing
@testable import EnsembleCore

@Suite struct GitHubRemoteTests {
    @Test(arguments: [
        "https://github.com/octo/widgets.git",
        "https://github.com/octo/widgets",
        "https://github.com/octo/widgets/",
        "https://user:token@github.com/octo/widgets.git",
        "http://www.github.com/octo/widgets",
        "git@github.com:octo/widgets.git",
        "git@github.com:octo/widgets",
        "github.com:octo/widgets.git",
        "ssh://git@github.com/octo/widgets.git",
        "ssh://git@github.com:22/octo/widgets",
        "git://github.com/octo/widgets.git",
        "  https://GitHub.com/octo/widgets.git\n",
    ])
    func parsesGitHubRemotes(_ remote: String) {
        #expect(GitHubRemote.parse(remote) == "octo/widgets")
    }

    @Test func keepsDotsAndDashesInNames() {
        #expect(GitHubRemote.parse("git@github.com:my-org/site.github.io.git") == "my-org/site.github.io")
    }

    @Test(arguments: [
        "",
        "https://gitlab.com/octo/widgets.git",
        "git@bitbucket.org:octo/widgets.git",
        "https://github.com/octo",
        "https://github.com/octo/widgets/tree/main",
        "/Users/me/code/widgets",
        "file:///Users/me/code/widgets",
        "../widgets",
        "git@github.com:octo/wid gets.git",
    ])
    func rejectsOtherRemotes(_ remote: String) {
        #expect(GitHubRemote.parse(remote) == nil)
    }

    @Test func acceptsCustomHosts() {
        #expect(GitHubRemote.parse("git@github.example.com:team/app.git", hosts: ["github.example.com"]) == "team/app")
    }

    @Test func readsOriginThroughGit() async throws {
        let repo = try await TestRepository.make(withInitialCommit: false)
        defer { repo.delete() }

        #expect(try await GitHubRemote.originRepository(in: repo.root, git: repo.git) == nil)

        try await repo.git.run(["remote", "add", "origin", "git@github.com:octo/widgets.git"], in: repo.root)
        #expect(try await GitHubRemote.originRepository(in: repo.root, git: repo.git) == "octo/widgets")

        try await repo.git.run(["remote", "set-url", "origin", "https://gitlab.com/octo/widgets.git"], in: repo.root)
        #expect(try await GitHubRemote.originRepository(in: repo.root, git: repo.git) == nil)
    }
}
