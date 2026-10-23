import Foundation
import Synchronization
import Testing
@testable import EnsembleCore

final class RecordingWriteBack: IssueWriteBack {
    enum Call: Equatable {
        case started(issue: Int, repository: String, workflow: String)
        case ended(issue: Int, conclusion: GitHubWriteBack.Conclusion, summary: String?, pullRequest: String?)
    }

    private let state = Mutex<(calls: [Call], failuresLeft: Int)>(([], 0))

    var calls: [Call] { state.withLock { $0.calls } }

    func failNext(_ count: Int) {
        state.withLock { $0.failuresLeft = count }
    }

    private func record(_ call: Call) throws {
        try state.withLock { state in
            if state.failuresLeft > 0 {
                state.failuresLeft -= 1
                throw GitHubError.http(status: 502, message: "Bad gateway")
            }
            state.calls.append(call)
        }
    }

    func runStarted(issue: Int, in repository: String, workflow: String) async throws {
        try record(.started(issue: issue, repository: repository, workflow: workflow))
    }

    func runEnded(
        issue: Int, in repository: String, workflow: String, conclusion: GitHubWriteBack.Conclusion,
        summary: String?, pullRequestURL: URL?
    ) async throws {
        try record(.ended(issue: issue, conclusion: conclusion, summary: summary, pullRequest: pullRequestURL?.absoluteString))
    }
}

@MainActor
@Suite(.serialized) struct RunWriteBackObserverTests {
    typealias H = WorkflowHarness

    func githubTask(_ h: H, number: Int = 42) throws -> ProjectTask {
        try h.database.insert(ProjectTask(
            projectId: try #require(h.project.id), title: "Fix VAT rounding", body: "", source: .github,
            sourceURL: "https://github.com/octo/widgets/issues/\(number)", workflow: "small-task", status: .incoming,
            externalNumber: number, repository: "octo/widgets", labels: ["small"], createdAt: .now, updatedAt: .now
        ))
    }

    func observer(_ h: H, _ writeBack: RecordingWriteBack) -> RunWriteBackObserver {
        RunWriteBackObserver(engine: h.engine, retryDelay: .seconds(3600)) { writeBack }
    }

    @Test func postsStartThenSuccessWithPullRequestWhenRunsChange() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let writeBack = RecordingWriteBack()
        let observer = observer(h, writeBack)
        observer.start()
        h.driver.script("build", H.done())
        h.driver.script("review", H.verdict(StepOutcome.approved, "Fine"))

        let run = try h.engine.start(task: try githubTask(h), workflow: try h.workflow("small-task"), project: h.project)
        let id = try #require(run.id)
        try await waitUntil { writeBack.calls.count == 1 }
        #expect(writeBack.calls == [.started(issue: 42, repository: "octo/widgets", workflow: "Small task v1")])

        await h.settle(id)
        try h.engine.resolveApproval(try h.run(id), approved: true)
        await h.settle(id)
        try await waitUntil { writeBack.calls.count == 2 }

        #expect(try h.run(id).status == .succeeded)
        #expect(writeBack.calls.last == .ended(issue: 42, conclusion: .succeeded, summary: nil, pullRequest: "https://github.com/acme/shop/pull/\(id)"))
        try await waitUntil { (try? h.database.writeBackEvents(runId: id)) == [.started, .ended] }
        #expect(try h.database.writeBackEvents(runId: id) == [.started, .ended])
        observer.stop()
    }

    @Test func postsFailureWithTheRunError() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        let writeBack = RecordingWriteBack()
        let observer = observer(h, writeBack)
        observer.start()
        h.driver.script("build", .failure("Tests timed out"), .failure("Tests timed out"))

        let run = try h.engine.start(task: try githubTask(h, number: 7), workflow: try h.workflow("small-task"), project: h.project)
        let id = try #require(run.id)
        await h.settle(id)
        try h.engine.resolveFailure(try h.run(id), retry: false)
        try await waitUntil { writeBack.calls.count == 2 }

        guard case .ended(let issue, let conclusion, let summary, let pullRequest) = writeBack.calls.last else {
            Issue.record("Expected an end write-back, got \(writeBack.calls)")
            return
        }
        #expect(issue == 7)
        #expect(conclusion == .failed)
        #expect(summary?.contains("Tests timed out") == true, "\(String(describing: summary))")
        #expect(pullRequest == nil)
        observer.stop()
    }

    @Test func isIdempotentAcrossObserversAndIgnoresChatTasks() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", .hang)
        let writeBack = RecordingWriteBack()
        let first = observer(h, writeBack)

        let githubRun = try h.engine.start(task: try githubTask(h), workflow: try h.workflow("small-task"), project: h.project)
        _ = try h.engine.start(task: try h.makeTask(), workflow: try h.workflow("small-task"), project: h.project)
        await first.sync()
        await first.sync()
        let restarted = observer(h, writeBack)
        await restarted.sync()

        #expect(writeBack.calls == [.started(issue: 42, repository: "octo/widgets", workflow: "Small task v1")])
        #expect(try h.database.writeBackEvents(runId: try #require(githubRun.id)) == [.started])
        try await h.engine.cancel(try h.run(try #require(githubRun.id)))
        await restarted.sync()
        #expect(writeBack.calls.count == 1)
        for run in h.engine.runs.values { try await h.engine.cancel(run) }
    }

    @Test func failedPostsAreRetriedWithoutDuplicates() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", .hang)
        let writeBack = RecordingWriteBack()
        writeBack.failNext(1)
        let observer = observer(h, writeBack)

        let run = try h.engine.start(task: try githubTask(h), workflow: try h.workflow("small-task"), project: h.project)
        await observer.sync()
        #expect(writeBack.calls.isEmpty)
        #expect(observer.lastError?.contains("#42") == true)
        #expect(try h.database.writeBackEvents(runId: try #require(run.id)).isEmpty)

        await observer.sync()
        await observer.sync()
        #expect(writeBack.calls.count == 1)
        #expect(observer.lastError == nil)
        try await h.engine.cancel(try h.run(try #require(run.id)))
    }

    @Test func noPublisherMeansNothingIsSentOrRecorded() async throws {
        let h = try H.make()
        defer { h.cleanUp() }
        h.driver.script("build", .hang)
        let observer = RunWriteBackObserver(engine: h.engine) { nil }
        let run = try h.engine.start(task: try githubTask(h), workflow: try h.workflow("small-task"), project: h.project)
        await observer.sync()
        #expect(try h.database.pendingGitHubWriteBacks().map(\.run.id) == [run.id])
        try await h.engine.cancel(try h.run(try #require(run.id)))
        #expect(try h.database.pendingGitHubWriteBacks().isEmpty)
    }
}
