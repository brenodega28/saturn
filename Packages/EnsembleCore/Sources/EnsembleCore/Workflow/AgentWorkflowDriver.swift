import Foundation

public enum WorkflowDriverError: Error, LocalizedError, Equatable {
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let reason): reason
        }
    }
}

@MainActor
public final class AgentWorkflowDriver: WorkflowDriver {
    public let runtime: AgentRuntime
    public var gitProvider: @MainActor () -> GitClient? = { nil }
    public var gitHubProvider: @MainActor () -> GitHubClient? = { nil }

    public init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    public func runAgentStep(_ context: StepContext) async throws -> StepResult {
        throw WorkflowDriverError.notReady("Agent steps aren’t wired yet.")
    }

    public func runSpawnStep(_ context: SpawnContext) async throws -> StepResult {
        throw WorkflowDriverError.notReady("Spawn steps aren’t wired yet.")
    }

    public func diffInfo(_ run: Run) async -> DiffInfo {
        DiffInfo(paths: [], lines: 0)
    }

    public func finish(_ run: Run, end: WorkflowEnd) async throws -> FinishResult {
        throw WorkflowDriverError.notReady("End actions aren’t wired yet.")
    }

    public func cancel(_ run: Run) async {}
}
