import Foundation
import Testing
@testable import SaturnCore

@Suite struct ProviderModeTests {
    let shell = [
        "PATH": "/usr/bin",
        "HOME": "/Users/me",
        "ANTHROPIC_API_KEY": "sk-ant-shell",
        "ANTHROPIC_AUTH_TOKEN": "token",
        "ANTHROPIC_BASE_URL": "https://proxy.example",
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "CLAUDECODE": "1",
    ]

    @Test func signInStripsEveryCredentialFromTheEnvironment() {
        let environment = ProviderMode.claudeSignIn.environment(base: shell, apiKey: "sk-ant-ignored")
        #expect(environment == ["PATH": "/usr/bin", "HOME": "/Users/me"])
    }

    @Test func apiKeyModeSetsOnlyTheStoredKey() {
        let environment = ProviderMode.apiKey.environment(base: shell, apiKey: "sk-ant-keychain")
        #expect(environment == ["PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "sk-ant-keychain"])
    }
}

@MainActor
@Suite(.serialized) struct ProviderEnforcementTests {
    @Test func signInRunsWithoutAnyKeyEvenWhenTheShellHasOne() async throws {
        let harness = try await AgentHarness.make(provider: .claudeSignIn, secrets: InMemorySecretStore([.anthropicAPIKey: "sk-ant-keychain"]))
        defer { harness.cleanUp() }

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        #expect(harness.launchEnvironments() == ["key= token="])
        #expect(session.transcript.session?.apiKeySource == "none")
    }

    @Test func apiKeyModeRunsWithTheKeychainKey() async throws {
        let harness = try await AgentHarness.make(provider: .apiKey, secrets: InMemorySecretStore([.anthropicAPIKey: "sk-ant-keychain"]))
        defer { harness.cleanUp() }

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        #expect(harness.launchEnvironments() == ["key=sk-ant-keychain token="])
        #expect(session.transcript.session?.apiKeySource == "ANTHROPIC_API_KEY")
    }

    @Test func apiKeyModeWithoutAStoredKeyNeverLaunches() async throws {
        let harness = try await AgentHarness.make(provider: .apiKey)
        defer { harness.cleanUp() }

        let session = try await harness.spawn()

        #expect(session.agent.status == .failed)
        #expect(session.agent.lastError == ProviderError.apiKeyMissing.localizedDescription)
        #expect(harness.launches().isEmpty)
    }

    @Test func refusesToSpawnBeforeAModeIsChosen() async throws {
        let harness = try await AgentHarness.make(provider: nil)
        defer { harness.cleanUp() }

        await #expect(throws: AgentError.providerNotChosen) { try await harness.spawn() }
        #expect(try await harness.repo.manager.list().isEmpty)
        #expect(harness.launches().isEmpty)
    }

    @Test func existingAgentCannotRunAfterTheModeIsCleared() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        harness.runtime.providerMode = nil
        session.send("more")

        #expect(session.agent.status == .failed)
        #expect(harness.launches().count == 1)
    }

    @Test func killsTheTurnWhenClaudeUsesOtherCredentials() async throws {
        let harness = try await AgentHarness.make(mode: "wrongsource", provider: .claudeSignIn)
        defer { harness.cleanUp() }

        let session = try await harness.spawn()
        try await waitUntil(timeout: .seconds(3)) { session.agent.status == .failed }

        #expect(session.agent.lastError == ProviderError.wrongCredentials(expected: .claudeSignIn, actualSource: "apiKeyHelper").localizedDescription)
        #expect(!session.isRunning)
        #expect(!session.transcript.entries.contains { if case .assistant = $0.content { true } else { false } })
    }
}
