import Foundation
import Observation

public protocol GitHubIssueSource: Sendable {
    func openIssues(in repository: String, label: String?) async throws -> [GitHubIssue]
}

extension GitHubClient: GitHubIssueSource {}

public enum GitHubPollerError: Error, Equatable, LocalizedError {
    case notSignedIn
    case notConfigured
    case backingOff(until: Date)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to GitHub in Settings › GitHub first."
        case .notConfigured: "Pick a repository and map at least one label to a workflow first."
        case .backingOff(let until): "GitHub rate limit reached. Ensemble will check again at \(until.formatted(date: .omitted, time: .shortened))."
        }
    }
}

public struct GitHubPollResult: Sendable, Hashable {
    public var imported: [ProjectTask]
    public var autoStarted: [Int64]

    public init(imported: [ProjectTask] = [], autoStarted: [Int64] = []) {
        self.imported = imported
        self.autoStarted = autoStarted
    }
}

@MainActor
@Observable
public final class GitHubPoller {
    public typealias StartWorkflow = @MainActor (ProjectTask, GitHubMapping, Project) throws -> Void

    public static let baseBackoff: TimeInterval = 60
    public static let maximumBackoff: TimeInterval = 30 * 60

    public private(set) var lastPolledAt: [Int64: Date] = [:]
    public private(set) var lastErrors: [Int64: String] = [:]
    public private(set) var backoffUntil: Date?
    public private(set) var pollingProjects: Set<Int64> = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let source: @MainActor () -> (any GitHubIssueSource)?
    @ObservationIgnored private let startWorkflow: StartWorkflow
    @ObservationIgnored private let tick: Duration
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var consecutiveRateLimits = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(
        database: AppDatabase,
        source: @escaping @MainActor () -> (any GitHubIssueSource)?,
        startWorkflow: @escaping StartWorkflow,
        tick: Duration = .seconds(30),
        clock: @escaping @MainActor () -> Date = { .now }
    ) {
        self.database = database
        self.source = source
        self.startWorkflow = startWorkflow
        self.tick = tick
        self.clock = clock
    }

    public var isRunning: Bool { loop != nil }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, tick] in
            while !Task.isCancelled {
                await self?.pollDueProjects()
                try? await Task.sleep(for: tick)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public static func isConfigured(_ project: Project) -> Bool {
        guard !project.isRemote, let repository = project.settings.githubRepository, !repository.isEmpty else { return false }
        return !activeMappings(project).isEmpty
    }

    public func isDue(_ project: Project, now: Date) -> Bool {
        guard let id = project.id, Self.isConfigured(project), !pollingProjects.contains(id) else { return false }
        guard let last = lastPolledAt[id] else { return true }
        let interval = TimeInterval(max(project.settings.githubPollMinutes, 1) * 60)
        return now.timeIntervalSince(last) >= interval
    }

    public func isBackingOff(at now: Date) -> Bool {
        backoffUntil.map { now < $0 } ?? false
    }

    @discardableResult
    public func pollDueProjects() async -> [ProjectTask] {
        let now = clock()
        guard !isBackingOff(at: now), source() != nil else { return [] }
        let projects = (try? database.openProjects()) ?? []
        var imported: [ProjectTask] = []
        for project in projects where isDue(project, now: clock()) {
            guard !isBackingOff(at: clock()) else { break }
            if let result = try? await poll(project) {
                imported += result.imported
            }
        }
        return imported
    }

    @discardableResult
    public func poll(_ project: Project) async throws -> GitHubPollResult {
        guard let projectID = project.id, Self.isConfigured(project),
              let repository = project.settings.githubRepository else { throw GitHubPollerError.notConfigured }
        guard let source = source() else { throw GitHubPollerError.notSignedIn }
        if let backoffUntil, clock() < backoffUntil { throw GitHubPollerError.backingOff(until: backoffUntil) }
        guard !pollingProjects.contains(projectID) else { return GitHubPollResult() }
        pollingProjects.insert(projectID)
        defer { pollingProjects.remove(projectID) }

        var result = GitHubPollResult()
        var startFailure: String?
        do {
            for mapping in Self.activeMappings(project) {
                let issues = try await source.openIssues(in: repository, label: mapping.label)
                for issue in issues.sorted(by: { $0.number < $1.number }) {
                    guard let task = try importIfNew(issue, repository: repository, mapping: mapping, projectID: projectID) else { continue }
                    result.imported.append(task)
                    if mapping.autoStart, let taskID = task.id {
                        do {
                            try startWorkflow(task, mapping, project)
                            result.autoStarted.append(taskID)
                        } catch {
                            startFailure = "Couldn’t start \(mapping.workflow) for #\(issue.number): \(error.localizedDescription)"
                        }
                    }
                }
            }
        } catch let GitHubError.rateLimited(resetAt) {
            let until = registerRateLimit(resetAt: resetAt)
            lastPolledAt[projectID] = clock()
            lastErrors[projectID] = GitHubError.rateLimited(resetAt: until).localizedDescription
            throw GitHubPollerError.backingOff(until: until)
        } catch {
            lastPolledAt[projectID] = clock()
            lastErrors[projectID] = error.localizedDescription
            throw error
        }
        consecutiveRateLimits = 0
        backoffUntil = nil
        lastPolledAt[projectID] = clock()
        lastErrors[projectID] = startFailure
        return result
    }

    static func activeMappings(_ project: Project) -> [GitHubMapping] {
        project.settings.githubMappings.filter {
            !$0.label.trimmingCharacters(in: .whitespaces).isEmpty && !$0.workflow.isEmpty
        }
    }

    private func importIfNew(_ issue: GitHubIssue, repository: String, mapping: GitHubMapping, projectID: Int64) throws -> ProjectTask? {
        guard !issue.isPullRequest, try !database.hasImportedIssue(issue.number, repository: repository) else { return nil }
        let now = clock()
        return try database.insert(ProjectTask(
            projectId: projectID,
            title: issue.title,
            body: issue.body ?? "",
            source: .github,
            sourceURL: issue.htmlURL.absoluteString,
            workflow: mapping.workflow,
            status: .incoming,
            externalNumber: issue.number,
            repository: repository,
            labels: issue.labelNames,
            createdAt: now,
            updatedAt: now
        ))
    }

    private func registerRateLimit(resetAt: Date?) -> Date {
        consecutiveRateLimits += 1
        let now = clock()
        let exponential = min(Self.baseBackoff * pow(2, Double(consecutiveRateLimits - 1)), Self.maximumBackoff)
        let until = max(resetAt ?? now.addingTimeInterval(exponential), now.addingTimeInterval(Self.baseBackoff))
        backoffUntil = until
        return until
    }
}
