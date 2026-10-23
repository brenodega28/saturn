import Foundation
import Synchronization
import Testing
@testable import EnsembleCore

final class FakeIssueSource: GitHubIssueSource {
    private let state = Mutex<(issues: [String: [GitHubIssue]], failures: [GitHubError], requests: [String])>(([:], [], []))

    func setIssues(_ issues: [GitHubIssue], label: String) {
        state.withLock { $0.issues[label] = issues }
    }

    func failNext(_ error: GitHubError) {
        state.withLock { $0.failures.append(error) }
    }

    var requests: [String] {
        state.withLock { $0.requests }
    }

    func openIssues(in repository: String, label: String?) async throws -> [GitHubIssue] {
        let outcome: Result<[GitHubIssue], GitHubError> = state.withLock { state in
            state.requests.append("\(repository)?\(label ?? "")")
            if !state.failures.isEmpty {
                return .failure(state.failures.removeFirst())
            }
            return .success(state.issues[label ?? ""] ?? [])
        }
        return try outcome.get()
    }

    static func issue(_ number: Int, labels: [String], title: String? = nil) -> GitHubIssue {
        GitHubIssue(
            id: 1000 + number, number: number, title: title ?? "Issue \(number)", body: "Body \(number)",
            htmlURL: URL(string: "https://github.com/octo/widgets/issues/\(number)")!,
            labels: labels.map { GitHubLabel(name: $0, color: "ededed") },
            createdAt: .now, updatedAt: .now
        )
    }
}

@MainActor
final class PollerClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(minutes: Double) {
        now = now.addingTimeInterval(minutes * 60)
    }
}

@MainActor
@Suite(.serialized) struct GitHubPollerTests {
    let database: AppDatabase
    let source = FakeIssueSource()
    let clock = PollerClock()
    var project: Project

    init() throws {
        database = try AppDatabase.inMemory()
        project = try database.openProject(at: URL(fileURLWithPath: "/tmp/ensemble-poller-\(UUID().uuidString)"))
        let projectID = try #require(project.id)
        try database.updateSettings(ProjectSettings(
            githubRepository: "octo/widgets",
            githubMappings: [
                GitHubMapping(label: "agent-ready", workflow: "feature-delivery"),
                GitHubMapping(label: "small", workflow: "small-task", autoStart: true),
            ],
            githubPollMinutes: 5
        ), forProject: projectID)
        project = try #require(try database.project(id: projectID))
    }

    func makePoller(started: @escaping GitHubPoller.StartWorkflow = { _, _, _ in }) -> GitHubPoller {
        let source = source
        let clock = clock
        return GitHubPoller(database: database, source: { source }, startWorkflow: started, clock: { clock.now })
    }

    func tasks() throws -> [ProjectTask] {
        try database.writer.read { db in try ProjectTask.order(ProjectTask.Columns.externalNumber).fetchAll(db) }
    }

    @Test func importsIssuesPerMappedLabelAsIncomingTasks() async throws {
        source.setIssues([FakeIssueSource.issue(234, labels: ["agent-ready", "backend"], title: "Refund reason column")], label: "agent-ready")
        let poller = makePoller()

        let result = try await poller.poll(project)

        #expect(source.requests == ["octo/widgets?agent-ready", "octo/widgets?small"])
        #expect(result.imported.count == 1)
        let task = try #require(try tasks().first)
        #expect(task.title == "Refund reason column")
        #expect(task.body == "Body 234")
        #expect(task.source == .github)
        #expect(task.status == .incoming)
        #expect(task.externalNumber == 234)
        #expect(task.repository == "octo/widgets")
        #expect(task.sourceURL == "https://github.com/octo/widgets/issues/234")
        #expect(task.labels == ["agent-ready", "backend"])
        #expect(task.workflow == "feature-delivery")
        #expect(poller.lastPolledAt[try #require(project.id)] == clock.now)
    }

    @Test func dedupesByRepositoryAndNumberAcrossPollsAndLabels() async throws {
        let both = FakeIssueSource.issue(7, labels: ["agent-ready", "small"])
        source.setIssues([both, FakeIssueSource.issue(8, labels: ["agent-ready"])], label: "agent-ready")
        source.setIssues([both], label: "small")
        let poller = makePoller()

        let first = try await poller.poll(project)
        let second = try await poller.poll(project)

        #expect(first.imported.map(\.externalNumber) == [7, 8])
        #expect(second.imported.isEmpty)
        #expect(try tasks().map(\.externalNumber) == [7, 8])
        #expect(try tasks().first?.workflow == "feature-delivery")
    }

    @Test func dismissedTasksAreNotReimported() async throws {
        source.setIssues([FakeIssueSource.issue(3, labels: ["agent-ready"])], label: "agent-ready")
        let poller = makePoller()
        try await poller.poll(project)
        try database.dismissTask(id: try #require(try tasks().first?.id))

        let again = try await poller.poll(project)

        #expect(again.imported.isEmpty)
        #expect(try tasks().map(\.status) == [.dismissed])
    }

    @Test func autoStartMappingsStartTheMappedWorkflow() async throws {
        source.setIssues([FakeIssueSource.issue(1, labels: ["agent-ready"])], label: "agent-ready")
        source.setIssues([FakeIssueSource.issue(2, labels: ["small"])], label: "small")
        var started: [(Int?, String)] = []
        let poller = makePoller { task, mapping, _ in started.append((task.externalNumber, mapping.workflow)) }

        let result = try await poller.poll(project)

        #expect(started.map(\.0) == [2])
        #expect(started.map(\.1) == ["small-task"])
        #expect(result.autoStarted == [try #require(try tasks().last?.id)])
    }

    @Test func autoStartFailureLeavesTaskIncomingAndRecordsError() async throws {
        source.setIssues([FakeIssueSource.issue(2, labels: ["small"])], label: "small")
        let poller = makePoller { _, _, _ in throw RunEngineError.emptyWorkflow("Small task") }

        let result = try await poller.poll(project)

        #expect(result.imported.count == 1)
        #expect(result.autoStarted.isEmpty)
        #expect(try tasks().first?.status == .incoming)
        #expect(poller.lastErrors[try #require(project.id)]?.contains("small-task") == true)
    }

    @Test func pollDueRespectsTheIntervalAndSkipsUnconfiguredProjects() async throws {
        let other = try database.openProject(at: URL(fileURLWithPath: "/tmp/ensemble-poller-other-\(UUID().uuidString)"))
        #expect(!GitHubPoller.isConfigured(other))
        let poller = makePoller()

        await poller.pollDueProjects()
        #expect(source.requests.count == 2)

        clock.advance(minutes: 4)
        await poller.pollDueProjects()
        #expect(source.requests.count == 2)

        clock.advance(minutes: 1)
        await poller.pollDueProjects()
        #expect(source.requests.count == 4)
    }

    @Test func rateLimitBacksOffUntilResetThenResumes() async throws {
        let reset = clock.now.addingTimeInterval(600)
        source.failNext(.rateLimited(resetAt: reset))
        source.setIssues([FakeIssueSource.issue(5, labels: ["agent-ready"])], label: "agent-ready")
        let poller = makePoller()

        await #expect(throws: GitHubPollerError.backingOff(until: reset)) { try await poller.poll(project) }
        #expect(poller.backoffUntil == reset)
        #expect(source.requests.count == 1)

        clock.advance(minutes: 6)
        await poller.pollDueProjects()
        await #expect(throws: GitHubPollerError.backingOff(until: reset)) { try await poller.poll(project) }
        #expect(source.requests.count == 1)

        clock.advance(minutes: 5)
        let imported = await poller.pollDueProjects()
        #expect(imported.map(\.externalNumber) == [5])
        #expect(poller.backoffUntil == nil)
        #expect(poller.lastErrors[try #require(project.id)] == nil)
    }

    @Test func rateLimitWithoutResetBacksOffExponentially() async throws {
        source.failNext(.rateLimited(resetAt: nil))
        source.failNext(.rateLimited(resetAt: nil))
        let poller = makePoller()
        let start = clock.now

        _ = try? await poller.poll(project)
        #expect(poller.backoffUntil == start.addingTimeInterval(60))

        clock.advance(minutes: 1)
        _ = try? await poller.poll(project)
        #expect(poller.backoffUntil == clock.now.addingTimeInterval(120))
    }

    @Test func rateLimitResponsesFromGitHubAreRecognised() async throws {
        let stub = HTTPStub()
        stub.enqueue(.json(403, #"{"message": "API rate limit exceeded"}"#, headers: [
            "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000900",
        ]))
        let client = GitHubClient(token: "tok", session: stub.session)
        let clock = clock
        let poller = GitHubPoller(database: database, source: { client }, startWorkflow: { _, _, _ in }, clock: { clock.now })

        await #expect(throws: GitHubPollerError.backingOff(until: Date(timeIntervalSince1970: 1_800_000_900))) {
            try await poller.poll(project)
        }
        #expect(stub.requests.first?.query["labels"] == "agent-ready")
        #expect(stub.requests.first?.query["state"] == "open")
    }

    @Test func pollingWithoutSignInOrConfigurationFails() async throws {
        let signedOut = GitHubPoller(database: database, source: { nil }, startWorkflow: { _, _, _ in })
        await #expect(throws: GitHubPollerError.notSignedIn) { try await signedOut.poll(project) }

        var unconfigured = project
        unconfigured.settings.githubMappings = [GitHubMapping(label: " ", workflow: "small-task")]
        await #expect(throws: GitHubPollerError.notConfigured) { try await makePoller().poll(unconfigured) }
    }

    @Test func mappingDecodesWithoutAutoStart() throws {
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"githubMappings":[{"label":"a","workflow":"b"}]}"#.utf8))
        #expect(decoded.githubMappings == [GitHubMapping(label: "a", workflow: "b", autoStart: false)])
        let roundTrip = try JSONDecoder().decode(GitHubMapping.self, from: try JSONEncoder().encode(GitHubMapping(label: "a", workflow: "b", autoStart: true)))
        #expect(roundTrip.autoStart)
    }
}
