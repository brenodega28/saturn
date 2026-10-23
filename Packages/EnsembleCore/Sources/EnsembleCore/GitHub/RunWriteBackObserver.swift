import Foundation
import Observation

public protocol IssueWriteBack: Sendable {
    func runStarted(issue: Int, in repository: String, workflow: String) async throws
    func runEnded(
        issue: Int, in repository: String, workflow: String, conclusion: GitHubWriteBack.Conclusion,
        summary: String?, pullRequestURL: URL?
    ) async throws
}

extension GitHubClient: IssueWriteBack {
    public func runStarted(issue: Int, in repository: String, workflow: String) async throws {
        try await GitHubWriteBack(client: self, repository: repository).runStarted(issue: issue, workflow: workflow)
    }

    public func runEnded(
        issue: Int, in repository: String, workflow: String, conclusion: GitHubWriteBack.Conclusion,
        summary: String?, pullRequestURL: URL?
    ) async throws {
        try await GitHubWriteBack(client: self, repository: repository).runEnded(
            issue: issue, workflow: workflow, conclusion: conclusion, summary: summary, pullRequestURL: pullRequestURL
        )
    }
}

@MainActor
@Observable
public final class RunWriteBackObserver {
    public private(set) var lastError: String?
    public private(set) var sentCount = 0

    @ObservationIgnored private let engine: RunEngine
    @ObservationIgnored private let publisher: @MainActor () -> (any IssueWriteBack)?
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var retry: Task<Void, Never>?

    public init(
        engine: RunEngine,
        retryDelay: Duration = .seconds(120),
        publisher: @escaping @MainActor () -> (any IssueWriteBack)?
    ) {
        self.engine = engine
        self.retryDelay = retryDelay
        self.publisher = publisher
    }

    private var database: AppDatabase { engine.database }

    public func start() {
        guard !isObserving else { return }
        isObserving = true
        observeRuns()
        requestSync()
    }

    public func stop() {
        isObserving = false
        retry?.cancel()
        retry = nil
    }

    public func requestSync() {
        if pass != nil {
            needsAnotherPass = true
            return
        }
        pass = Task { [weak self] in await self?.drain() }
    }

    public func sync() async {
        requestSync()
        while let pass {
            await pass.value
        }
    }

    private func observeRuns() {
        guard isObserving else { return }
        withObservationTracking {
            _ = engine.runs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeRuns()
                self?.requestSync()
            }
        }
    }

    private func drain() async {
        repeat {
            needsAnotherPass = false
            await syncOnce()
        } while needsAnotherPass
        pass = nil
    }

    private func syncOnce() async {
        guard let publisher = publisher() else { return }
        let pending: [PendingWriteBack]
        do {
            pending = try database.pendingGitHubWriteBacks()
        } catch {
            lastError = error.localizedDescription
            return
        }
        for item in pending {
            do {
                try await send(item, with: publisher)
            } catch {
                lastError = "Couldn’t update GitHub issue #\(item.issue): \(error.localizedDescription)"
                scheduleRetry()
                return
            }
        }
        lastError = nil
    }

    private func send(_ item: PendingWriteBack, with publisher: any IssueWriteBack) async throws {
        guard let runID = item.run.id else { return }
        let workflow = workflowName(for: item.run)
        if item.needsStart {
            try await publisher.runStarted(issue: item.issue, in: item.repository, workflow: workflow)
            try database.recordWriteBack(.started, runId: runID)
            sentCount += 1
        }
        guard let conclusion = item.conclusion, !item.endedSent else { return }
        let run = try database.run(id: runID) ?? item.run
        try await publisher.runEnded(
            issue: item.issue,
            in: item.repository,
            workflow: workflow,
            conclusion: conclusion,
            summary: conclusion == .failed ? failureSummary(for: run) : nil,
            pullRequestURL: run.pullRequestURL.flatMap(URL.init(string:))
        )
        try database.recordWriteBack(.ended, runId: runID)
        sentCount += 1
    }

    private func failureSummary(for run: Run) -> String? {
        let failedStepDetail = run.id
            .flatMap { try? database.runSteps(runId: $0) }?
            .last { $0.status == .failed }?
            .output
            .flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)).summary }
        let parts = [run.lastError, failedStepDetail].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let headline = parts.first else { return nil }
        guard let detail = parts.dropFirst().first, !headline.contains(detail) else { return headline }
        return "\(headline): \(detail)"
    }

    private func workflowName(for run: Run) -> String {
        run.workflowDefinition?.displayName ?? run.workflow
    }

    private func scheduleRetry() {
        guard isObserving, retry == nil else { return }
        retry = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            self?.retry = nil
            self?.requestSync()
        }
    }
}
