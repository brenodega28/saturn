import Foundation
import Testing
@testable import EnsembleCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENSEMBLE_REAL_GITHUB_TOKEN"] != nil))
struct RealGitHubTests {
    let environment = ProcessInfo.processInfo.environment

    @Test func exercisesTheScratchRepository() async throws {
        let token = try #require(environment["ENSEMBLE_REAL_GITHUB_TOKEN"])
        let repository = try #require(environment["ENSEMBLE_REAL_GITHUB_REPO"])
        let issueNumber = try #require(environment["ENSEMBLE_REAL_GITHUB_ISSUE"].flatMap(Int.init))
        let branch = try #require(environment["ENSEMBLE_REAL_GITHUB_BRANCH"])
        let client = GitHubClient(token: token)

        let user = try await client.currentUser()
        let repo = try await client.repository(repository)
        #expect(repo.isPrivate)
        #expect(repo.defaultBranch == "main")
        #expect(try await client.repositories().contains { $0.fullName == repository })

        let labelled = try await client.openIssues(in: repository, label: "feature")
        #expect(labelled.map(\.number).contains(issueNumber))

        let writeBack = GitHubWriteBack(client: client, repository: repository)
        try await writeBack.runStarted(issue: issueNumber, workflow: "Feature delivery v1")
        #expect(try await eventually { try await client.issue(issueNumber, in: repository).labelNames.contains("ensemble:running") })

        let pull = try await client.createPullRequest(
            NewPullRequest(title: "Ensemble real API check", head: branch, base: "main", body: "Created by Ensemble's GitHub client test.", draft: false),
            in: repository
        )
        #expect(try await client.pullRequest(forHead: branch, in: repository)?.number == pull.number)

        try await writeBack.runEnded(issue: issueNumber, workflow: "Feature delivery v1", conclusion: .succeeded, summary: "Checked by \(user.login).", pullRequestURL: pull.htmlURL)
        #expect(try await eventually {
            let labels = try await client.issue(issueNumber, in: repository).labelNames
            return labels.contains("ensemble:done") && !labels.contains("ensemble:running")
        })
        print("REAL_GITHUB_PR=\(pull.number)")
    }

    private func eventually(_ check: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<10 {
            if try await check() { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
