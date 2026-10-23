import Foundation
import Testing
@testable import EnsembleCore

@Suite struct GitHubClientTests {
    let stub = HTTPStub()
    var client: GitHubClient { GitHubClient(token: "tok-123", session: stub.session) }

    @Test func sendsStandardHeadersAndDecodesCurrentUser() async throws {
        stub.enqueue(.json(GitHubFixtures.user))

        let user = try await client.currentUser()

        #expect(user == GitHubUser(id: 7, login: "octocat", name: "The Octocat", avatarURL: URL(string: "https://avatars.example/7")))
        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.github.com/user")
        #expect(request.header("Accept") == "application/vnd.github+json")
        #expect(request.header("X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.header("Authorization") == "Bearer tok-123")
    }

    @Test func decodesRepository() async throws {
        stub.enqueue(.json(GitHubFixtures.repository()))

        let repository = try await client.repository("octo/widgets")

        #expect(stub.requests.first?.path == "/repos/octo/widgets")
        #expect(repository.fullName == "octo/widgets")
        #expect(repository.owner.login == "octo")
        #expect(repository.defaultBranch == "main")
        #expect(repository.isPrivate)
    }

    @Test func rejectsMalformedRepositoryNames() async throws {
        for name in ["widgets", "octo/", "a/b/c", "octo /widgets"] {
            await #expect(throws: GitHubError.invalidRepository(name)) { try await client.repository(name) }
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func listsOpenIssuesByLabelExcludingPullRequestsAcrossPages() async throws {
        let next = "https://api.github.com/repositories/1/issues?state=open&labels=ensemble%3Ago&per_page=100&page=2"
        let last = "https://api.github.com/repositories/1/issues?state=open&labels=ensemble%3Ago&per_page=100&page=2"
        stub.enqueue(
            .json(
                "[\(GitHubFixtures.issue(number: 1, labels: ["ensemble:go"])),\(GitHubFixtures.issue(number: 2, isPullRequest: true))]",
                headers: ["Link": #"<\#(next)>; rel="next", <\#(last)>; rel="last""#]
            ),
            .json("[\(GitHubFixtures.issue(number: 3, labels: ["ensemble:go", "bug"]))]", headers: ["Link": #"<https://api.github.com/repositories/1/issues?page=1>; rel="prev""#])
        )

        let issues = try await client.openIssues(in: "octo/widgets", label: "ensemble:go")

        #expect(issues.map(\.number) == [1, 3])
        #expect(issues[1].labelNames == ["ensemble:go", "bug"])
        #expect(issues[0].createdAt == Date(timeIntervalSince1970: 1_790_856_000))
        #expect(stub.requests.count == 2)
        let first = try #require(stub.requests.first)
        #expect(first.path == "/repos/octo/widgets/issues")
        #expect(first.query == ["state": "open", "labels": "ensemble:go", "per_page": "100"])
        #expect(stub.requests[1].url.absoluteString == next)
        #expect(stub.requests[1].header("Authorization") == "Bearer tok-123")
    }

    @Test func stopsPaginationAtForeignHosts() async throws {
        stub.enqueue(.json("[]", headers: ["Link": #"<https://evil.example/steal?page=2>; rel="next""#]))

        let repositories = try await client.repositories()

        #expect(repositories.isEmpty)
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].path == "/user/repos")
        #expect(stub.requests[0].query["per_page"] == "100")
    }

    @Test func paginatesRepositories() async throws {
        stub.enqueue(
            .json("[\(GitHubFixtures.repository(id: 1, fullName: "octo/a"))]", headers: ["Link": #"<https://api.github.com/user/repos?page=2>; rel="next""#]),
            .json("[\(GitHubFixtures.repository(id: 2, fullName: "octo/b", isPrivate: false))]")
        )

        let repositories = try await client.repositories()

        #expect(repositories.map(\.fullName) == ["octo/a", "octo/b"])
        #expect(repositories.map(\.isPrivate) == [true, false])
    }

    @Test func parsesLinkHeaders() {
        let header = #"<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=3>; rel="next", <https://api.github.com/x?page=9>; rel="last""#
        #expect(GitHubClient.nextPageURL(fromLinkHeader: header)?.absoluteString == "https://api.github.com/x?page=3")
        #expect(GitHubClient.nextPageURL(fromLinkHeader: #"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
        #expect(GitHubClient.nextPageURL(fromLinkHeader: nil) == nil)
    }

    @Test func getsIssue() async throws {
        stub.enqueue(.json(GitHubFixtures.issue(number: 42)))

        let issue = try await client.issue(42, in: "octo/widgets")

        #expect(issue.number == 42)
        #expect(issue.body == "Body 42")
        #expect(!issue.isPullRequest)
        #expect(stub.requests.first?.path == "/repos/octo/widgets/issues/42")
    }

    @Test func addsAndRemovesLabels() async throws {
        stub.enqueue(
            .json("[\(GitHubFixtures.label("ensemble:running"))]"),
            .json("[]"),
            .json(404, #"{"message": "Label does not exist"}"#)
        )

        let labels = try await client.addLabels(["ensemble:running"], toIssue: 5, in: "octo/widgets")
        try await client.removeLabel("ensemble:running", fromIssue: 5, in: "octo/widgets")
        try await client.removeLabel("ensemble:running", fromIssue: 5, in: "octo/widgets")

        #expect(labels.map(\.name) == ["ensemble:running"])
        let add = stub.requests[0]
        #expect(add.method == "POST")
        #expect(add.path == "/repos/octo/widgets/issues/5/labels")
        #expect(add.header("Content-Type") == "application/json")
        #expect(add.jsonBody()?["labels"] as? [String] == ["ensemble:running"])
        #expect(stub.requests[1].method == "DELETE")
        #expect(stub.requests[1].path == "/repos/octo/widgets/issues/5/labels/ensemble:running")
    }

    @Test func percentEncodesLabelPathSegments() async throws {
        stub.enqueue(.json("[]"))

        try await client.removeLabel("needs review/ui", fromIssue: 1, in: "octo/widgets")

        #expect(stub.requests.first?.path == "/repos/octo/widgets/issues/1/labels/needs%20review%2Fui")
    }

    @Test func ensureLabelKeepsExistingLabel() async throws {
        stub.enqueue(.json(GitHubFixtures.label("ensemble:done", color: "0e8a16")))

        let label = try await client.ensureLabel("ensemble:done", color: "#00ff00", in: "octo/widgets")

        #expect(label.color == "0e8a16")
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].method == "GET")
        #expect(stub.requests[0].path == "/repos/octo/widgets/labels/ensemble:done")
    }

    @Test func ensureLabelCreatesMissingLabel() async throws {
        stub.enqueue(
            .json(404, #"{"message": "Not Found"}"#),
            .json(201, GitHubFixtures.label("ensemble:done", color: "00ff00"))
        )

        let label = try await client.ensureLabel("ensemble:done", color: "#00ff00", description: "Done", in: "octo/widgets")

        #expect(label.name == "ensemble:done")
        let create = stub.requests[1]
        #expect(create.method == "POST")
        #expect(create.path == "/repos/octo/widgets/labels")
        #expect(create.jsonBody()?["name"] as? String == "ensemble:done")
        #expect(create.jsonBody()?["color"] as? String == "00ff00")
        #expect(create.jsonBody()?["description"] as? String == "Done")
    }

    @Test func ensureLabelToleratesCreationRace() async throws {
        stub.enqueue(
            .json(404, #"{"message": "Not Found"}"#),
            .json(422, #"{"message": "Validation Failed", "errors": [{"resource": "Label", "code": "already_exists", "field": "name"}]}"#),
            .json(GitHubFixtures.label("ensemble:done"))
        )

        let label = try await client.ensureLabel("ensemble:done", color: "00ff00", in: "octo/widgets")

        #expect(label.name == "ensemble:done")
        #expect(stub.requests.map(\.method) == ["GET", "POST", "GET"])
    }

    @Test func createsComment() async throws {
        stub.enqueue(.json(201, GitHubFixtures.comment(body: "Hello")))

        let comment = try await client.createComment("Hello", onIssue: 1, in: "octo/widgets")

        #expect(comment.id == 55)
        #expect(stub.requests[0].method == "POST")
        #expect(stub.requests[0].path == "/repos/octo/widgets/issues/1/comments")
        #expect(stub.requests[0].jsonBody()?["body"] as? String == "Hello")
    }

    @Test func createsPullRequest() async throws {
        stub.enqueue(.json(201, GitHubFixtures.pullRequest()))

        let pullRequest = try await client.createPullRequest(
            NewPullRequest(title: "Fix", head: "crew/dev/fix", base: "main", body: "Closes #1", draft: true),
            in: "octo/widgets"
        )

        #expect(pullRequest.number == 9)
        #expect(pullRequest.isDraft)
        #expect(pullRequest.head.ref == "crew/dev/fix")
        #expect(pullRequest.htmlURL.absoluteString == "https://github.com/octo/widgets/pull/9")
        let body = try #require(stub.requests[0].jsonBody())
        #expect(stub.requests[0].method == "POST")
        #expect(stub.requests[0].path == "/repos/octo/widgets/pulls")
        #expect(body["title"] as? String == "Fix")
        #expect(body["head"] as? String == "crew/dev/fix")
        #expect(body["base"] as? String == "main")
        #expect(body["body"] as? String == "Closes #1")
        #expect(body["draft"] as? Bool == true)
    }

    @Test func findsPullRequestByHeadBranch() async throws {
        stub.enqueue(.json("[\(GitHubFixtures.pullRequest())]"), .json("[]"))

        let found = try await client.pullRequest(forHead: "crew/dev/fix", in: "octo/widgets")
        let missing = try await client.pullRequest(forHead: "fork:other", in: "octo/widgets", state: .all)

        #expect(found?.number == 9)
        #expect(missing == nil)
        #expect(stub.requests[0].path == "/repos/octo/widgets/pulls")
        #expect(stub.requests[0].query == ["head": "octo:crew/dev/fix", "state": "open"])
        #expect(stub.requests[1].query == ["head": "fork:other", "state": "all"])
    }

    @Test func mapsUnauthorizedAndNotFound() async throws {
        stub.enqueue(.json(401, #"{"message": "Bad credentials"}"#), .json(404, #"{"message": "Not Found"}"#))

        await #expect(throws: GitHubError.unauthorized) { try await client.currentUser() }
        await #expect(throws: GitHubError.notFound) { try await client.issue(1, in: "octo/widgets") }
    }

    @Test func mapsRateLimits() async throws {
        stub.enqueue(
            .json(403, #"{"message": "API rate limit exceeded"}"#, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"]),
            .json(429, #"{"message": "slow down"}"#),
            .json(403, #"{"message": "Resource not accessible by integration"}"#)
        )

        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000))) {
            try await client.currentUser()
        }
        await #expect(throws: GitHubError.rateLimited(resetAt: nil)) { try await client.currentUser() }
        await #expect(throws: GitHubError.http(status: 403, message: "Resource not accessible by integration")) {
            try await client.currentUser()
        }
    }

    @Test func mapsRetryAfterToResetDate() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = try #require(HTTPURLResponse(
            url: URL(fileURLWithPath: "/"), statusCode: 403, httpVersion: nil, headerFields: ["Retry-After": "60"]
        ))
        #expect(GitHubClient.error(for: response, data: Data(), now: now) == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_060)))
    }

    @Test func mapsValidationAndOtherErrors() async throws {
        stub.enqueue(
            .json(422, #"{"message": "Validation Failed", "errors": [{"resource": "PullRequest", "code": "custom", "message": "A pull request already exists for octo:crew/dev/fix."}]}"#),
            .json(500, #"{"message": "Server Error"}"#),
            .json(502, "<html>bad gateway</html>")
        )
        let newPullRequest = NewPullRequest(title: "t", head: "h", base: "main")

        await #expect(throws: GitHubError.validation(message: "Validation Failed: A pull request already exists for octo:crew/dev/fix.")) {
            try await client.createPullRequest(newPullRequest, in: "octo/widgets")
        }
        await #expect(throws: GitHubError.http(status: 500, message: "Server Error")) { try await client.currentUser() }
        await #expect(throws: GitHubError.http(status: 502, message: "")) { try await client.currentUser() }
    }

    @Test func reportsDecodingFailures() async throws {
        stub.enqueue(.json(#"{"id": "not a number"}"#))

        await #expect {
            try await client.currentUser()
        } throws: { error in
            if case GitHubError.decoding = error { true } else { false }
        }
    }
}
