import Foundation

public struct GitHubWriteBack: Sendable {
    public enum Conclusion: String, Sendable, Hashable, CaseIterable {
        case succeeded
        case failed

        public var label: EnsembleLabel {
            switch self {
            case .succeeded: .done
            case .failed: .failed
            }
        }
    }

    public struct EnsembleLabel: Sendable, Hashable {
        public let name: String
        public let color: String
        public let description: String

        public static let running = EnsembleLabel(name: "ensemble:running", color: "fbca04", description: "An Ensemble run is working on this issue")
        public static let done = EnsembleLabel(name: "ensemble:done", color: "0e8a16", description: "An Ensemble run finished this issue")
        public static let failed = EnsembleLabel(name: "ensemble:failed", color: "d73a4a", description: "An Ensemble run failed on this issue")
    }

    public let client: GitHubClient
    public let repository: String

    public init(client: GitHubClient, repository: String) {
        self.client = client
        self.repository = repository
    }

    public static func startedComment(workflow: String) -> String {
        "Ensemble started \(workflow) for this issue."
    }

    public static func endedComment(
        workflow: String, conclusion: Conclusion, summary: String?, pullRequestURL: URL?
    ) -> String {
        let headline = switch conclusion {
        case .succeeded: "Ensemble finished \(workflow) for this issue."
        case .failed: "Ensemble \(workflow) failed for this issue."
        }
        var paragraphs = [headline]
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            paragraphs.append(summary)
        }
        if let pullRequestURL {
            paragraphs.append("Pull request: \(pullRequestURL.absoluteString)")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    public func runStarted(issue: Int, workflow: String) async throws {
        try await ensure(.running)
        try await client.createComment(Self.startedComment(workflow: workflow), onIssue: issue, in: repository)
        try await client.addLabels([EnsembleLabel.running.name], toIssue: issue, in: repository)
    }

    public func runEnded(
        issue: Int, workflow: String, conclusion: Conclusion, summary: String? = nil, pullRequestURL: URL? = nil
    ) async throws {
        let finalLabel = conclusion.label
        try await ensure(finalLabel)
        try await client.createComment(
            Self.endedComment(workflow: workflow, conclusion: conclusion, summary: summary, pullRequestURL: pullRequestURL),
            onIssue: issue,
            in: repository
        )
        for stale in [EnsembleLabel.running] + Conclusion.allCases.map(\.label) where stale != finalLabel {
            try await client.removeLabel(stale.name, fromIssue: issue, in: repository)
        }
        try await client.addLabels([finalLabel.name], toIssue: issue, in: repository)
    }

    private func ensure(_ label: EnsembleLabel) async throws {
        try await client.ensureLabel(label.name, color: label.color, description: label.description, in: repository)
    }
}
