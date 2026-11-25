import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct OnboardingTests {
    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "saturn-onboarding-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func record(_ version: Int, in repository: URL) throws {
        try FileManager.default.createDirectory(at: ProjectConfig.directory(in: repository), withIntermediateDirectories: true)
        try "version: \(version)\ncompleted_at: 2026-11-01T10:00:00Z\n".write(to: OnboardingRecord.file(in: repository), atomically: true, encoding: .utf8)
    }

    @Test func theBundledDefinitionShipsAtVersionOneWithoutForcing() {
        let bundled = OnboardingDefinition.load()
        #expect(bundled.version == 1)
        #expect(!bundled.forceOnboarding)
        #expect(bundled.instructions.contains("mcp__saturn__propose_setup"))
        #expect(bundled.instructions.contains("mission"))
        #expect(bundled.instructions.contains("`.saturn/specs`"))
        #expect(bundled.instructions.contains("`spec`"))
        #expect(bundled.instructions.contains("effectively empty"))
    }

    @Test func aProjectWithoutSaturnConfigNeedsOnboarding() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        #expect(OnboardingDefinition(version: 1).needsOnboarding(repository: repository))
        try FileManager.default.createDirectory(at: ProjectConfig.directory(in: repository), withIntermediateDirectories: true)
        #expect(!OnboardingDefinition(version: 1).needsOnboarding(repository: repository))
        #expect(OnboardingRecord.recordedVersion(in: repository) == 0)
    }

    @Test func onlyAForcedNewerVersionReopensOnboarding() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try record(1, in: repository)

        #expect(!OnboardingDefinition(version: 1, forceOnboarding: true).needsOnboarding(repository: repository))
        #expect(OnboardingDefinition(version: 2, forceOnboarding: true).needsOnboarding(repository: repository))
        #expect(!OnboardingDefinition(version: 2, forceOnboarding: false).needsOnboarding(repository: repository))
        #expect(OnboardingRecord.load(repository: repository)?.completedAt == (try Date("2026-11-01T10:00:00Z", strategy: .iso8601)))
    }

    @Test func theScanTreatsLicenceGitignoreAndAShortReadmeAsEmpty() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "node_modules\n".write(to: repository.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "MIT".write(to: repository.appending(path: "LICENSE"), atomically: true, encoding: .utf8)
        try "# Todo app\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repository.appending(path: ".saturn/workflows"), withIntermediateDirectories: true)
        try "name: x".write(to: repository.appending(path: ".saturn/workflows/x.yaml"), atomically: true, encoding: .utf8)

        let empty = ProjectScanner.scanFiles(repository: repository)
        #expect(empty.isEffectivelyEmpty)
        #expect(empty.onboardingSummary.contains("Effectively empty: yes"))

        try String(repeating: "A todo app for teams. ", count: 20).write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        #expect(!ProjectScanner.scanFiles(repository: repository).isEffectivelyEmpty)

        try "# Todo app\n".write(to: repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "{\"name\": \"todo\"}".write(to: repository.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let code = ProjectScanner.scanFiles(repository: repository)
        #expect(!code.isEffectivelyEmpty)
        #expect(code.onboardingSummary.contains("Technologies found: Node.js (package.json)"))
        #expect(code.onboardingSummary.contains("Docs found: README.md"))
    }

    @Test func aFreshlySetUpEmptyRepoStillScansAsEmpty() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "MIT".write(to: repository.appending(path: "LICENSE"), atomically: true, encoding: .utf8)
        let before = ProjectScanner.scanFiles(repository: repository)
        try ProjectSetupPlan.recommended(for: before).apply(to: repository)
        let written = try AgentInstructions.setUp(repository: repository)
        #expect(written == ["AGENTS.md", "CLAUDE.md"])

        let scan = ProjectScanner.scanFiles(repository: repository)
        #expect(scan.isEffectivelyEmpty)
        #expect(scan.onboardingSummary.contains("Effectively empty: yes"))

        try "# Agent instructions\n\nUse pnpm, never npm.\n".write(to: repository.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        #expect(!ProjectScanner.scanFiles(repository: repository).isEffectivelyEmpty)
        try AgentInstructions.template(repository: repository).write(to: repository.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try "@AGENTS.md\n\nAlways answer in French.\n".write(to: repository.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        #expect(!ProjectScanner.scanFiles(repository: repository).isEffectivelyEmpty)
    }

    func makeChat() async throws -> (WorkflowDriverTests.Setup, LeadChat) {
        let setup = try await WorkflowDriverTests().makeSetup()
        return (setup, LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver))
    }

    @Test func theOnboardingChatOpensWithSaturnsScanAndTheOnboardingBrief() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let scan = ProjectScanner.scanFiles(repository: setup.project.filesRoot)

        let onboarding = try await chat.openOnboarding(in: setup.project, scan: scan)
        #expect(onboarding.isOnboarding)
        #expect(try setup.harness.database.task(id: onboarding.id!)?.isOnboarding == true)
        let messages = try setup.harness.database.leadMessages(taskId: onboarding.id!)
        #expect(messages.first?.kind == .note)
        #expect(messages.first?.text == scan.onboardingSummary)
        #expect(!messages.contains { $0.kind == .user })

        let lead = try #require(try setup.harness.database.leadAgent(taskId: onboarding.id!))
        let prompt = try setup.harness.runtime.turnSetup(for: lead).systemPrompt
        #expect(prompt.contains("# Onboarding this project"))
        #expect(setup.driver.tools(for: lead).contains(.proposeSetup))
        let transcript = setup.harness.runtime.paths.transcript(lead.id!)
        try await waitUntil { ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "").contains("Saturn's scan of this project") }

        let regular = try await chat.createRequest("CHAT hello", in: setup.project)
        let regularLead = try #require(try setup.harness.database.leadAgent(taskId: regular.id!))
        #expect(!setup.driver.tools(for: regularLead).contains(.proposeSetup))
        #expect(!(try setup.harness.runtime.turnSetup(for: regularLead).systemPrompt.contains("# Onboarding this project")))
    }

    @Test func openingTheProjectAgainReusesTheOpenOnboardingChat() async throws {
        let (setup, chat) = try await makeChat()
        defer { setup.harness.cleanUp() }
        let scan = ProjectScanner.scanFiles(repository: setup.project.filesRoot)

        async let first = chat.openOnboarding(in: setup.project, scan: scan)
        async let second = chat.openOnboarding(in: setup.project, scan: scan)
        let (a, b) = try await (first, second)
        let third = try await chat.openOnboarding(in: setup.project, scan: scan)
        #expect(a.id == b.id && b.id == third.id)
        let onboardingChats = try setup.harness.database.leadRequests(projectId: setup.project.id!).filter(\.isOnboarding)
        #expect(onboardingChats.count == 1)

        _ = try setup.harness.database.setClosed(taskId: a.id!, reason: .dropped, at: .now)
        let reopened = try await chat.openOnboarding(in: setup.project, scan: scan)
        #expect(reopened.id != a.id)
    }
}
