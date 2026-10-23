import Foundation
import Testing
@testable import EnsembleCore

@Suite struct GitHubWriteBackTests {
    let stub = HTTPStub()
    var writeBack: GitHubWriteBack {
        GitHubWriteBack(client: GitHubClient(token: "tok", session: stub.session), repository: "octo/widgets")
    }

    @Test func runStartCreatesMissingLabelCommentsAndLabels() async throws {
        stub.enqueue(
            .json(404, #"{"message": "Not Found"}"#),
            .json(201, GitHubFixtures.label("ensemble:running")),
            .json(201, GitHubFixtures.comment()),
            .json("[\(GitHubFixtures.label("ensemble:running"))]")
        )

        try await writeBack.runStarted(issue: 12, workflow: "feature")

        let requests = stub.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "GET /repos/octo/widgets/labels/ensemble:running",
            "POST /repos/octo/widgets/labels",
            "POST /repos/octo/widgets/issues/12/comments",
            "POST /repos/octo/widgets/issues/12/labels",
        ])
        #expect(requests[1].jsonBody()?["color"] as? String == "fbca04")
        #expect(requests[2].jsonBody()?["body"] as? String == "Ensemble started feature for this issue.")
        #expect(requests[3].jsonBody()?["labels"] as? [String] == ["ensemble:running"])
        #expect(stub.pendingReplies == 0)
    }

    @Test func runStartSkipsCreatingExistingLabel() async throws {
        stub.enqueue(
            .json(GitHubFixtures.label("ensemble:running")),
            .json(201, GitHubFixtures.comment()),
            .json("[]")
        )

        try await writeBack.runStarted(issue: 12, workflow: "feature")

        #expect(stub.requests.map(\.method) == ["GET", "POST", "POST"])
        #expect(!stub.requests.contains { $0.path == "/repos/octo/widgets/labels" && $0.method == "POST" })
    }

    @Test func successfulRunEndCommentsWithPullRequestAndSwapsLabels() async throws {
        stub.enqueue(
            .json(GitHubFixtures.label("ensemble:done")),
            .json(201, GitHubFixtures.comment()),
            .json("[]"),
            .json(404, #"{"message": "Label does not exist"}"#),
            .json("[\(GitHubFixtures.label("ensemble:done"))]")
        )

        try await writeBack.runEnded(
            issue: 12, workflow: "feature", conclusion: .succeeded,
            summary: "Added refunds.", pullRequestURL: URL(string: "https://github.com/octo/widgets/pull/9")
        )

        let requests = stub.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "GET /repos/octo/widgets/labels/ensemble:done",
            "POST /repos/octo/widgets/issues/12/comments",
            "DELETE /repos/octo/widgets/issues/12/labels/ensemble:running",
            "DELETE /repos/octo/widgets/issues/12/labels/ensemble:failed",
            "POST /repos/octo/widgets/issues/12/labels",
        ])
        #expect(requests[1].jsonBody()?["body"] as? String == """
        Ensemble finished feature for this issue.

        Added refunds.

        Pull request: https://github.com/octo/widgets/pull/9
        """)
        #expect(requests[4].jsonBody()?["labels"] as? [String] == ["ensemble:done"])
    }

    @Test func failedRunEndAddsFailedLabel() async throws {
        stub.enqueue(
            .json(404, #"{"message": "Not Found"}"#),
            .json(201, GitHubFixtures.label("ensemble:failed")),
            .json(201, GitHubFixtures.comment()),
            .json("[]"),
            .json("[]"),
            .json("[]")
        )

        try await writeBack.runEnded(issue: 3, workflow: "bugfix", conclusion: .failed, summary: "Tests kept failing.")

        let requests = stub.requests
        #expect(requests[1].jsonBody()?["color"] as? String == "d73a4a")
        #expect(requests[2].jsonBody()?["body"] as? String == "Ensemble bugfix failed for this issue.\n\nTests kept failing.")
        #expect(requests[3].path.hasSuffix("/labels/ensemble:running"))
        #expect(requests[4].path.hasSuffix("/labels/ensemble:done"))
        #expect(requests[5].jsonBody()?["labels"] as? [String] == ["ensemble:failed"])
    }

    @Test func endedCommentWithoutExtras() {
        #expect(GitHubWriteBack.endedComment(workflow: "feature", conclusion: .succeeded, summary: "  ", pullRequestURL: nil)
            == "Ensemble finished feature for this issue.")
    }

    @Test func propagatesUnauthorized() async {
        stub.enqueue(.json(401, #"{"message": "Bad credentials"}"#))

        await #expect(throws: GitHubError.unauthorized) { try await writeBack.runStarted(issue: 1, workflow: "feature") }
        #expect(stub.requests.count == 1)
    }
}
