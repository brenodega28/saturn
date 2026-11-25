import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct SetupProposalTests {
    static let arguments: JSONValue = .object([
        "mission": .string("# Todo\n\n## Mission\nTodos for teams.\n\n## Vision\nThe team's daily plan."),
        "spec_folder": .string(".saturn/specs"),
        "agents": .array([
            .object([
                "id": .string("django-builder"), "name": .string("Django Builder"), "kind": .string("builder"), "model": .string("opus"),
                "description": .string("Builds the API."), "instructions": .string("Use the service layer."),
            ]),
            .object([
                "id": .string("api-reviewer"), "name": .string("API Reviewer"), "kind": .string("checker"),
                "description": .string("Reviews the API."), "instructions": .string("Check auth on every endpoint."),
            ]),
        ]),
        "workflow": .object([
            "id": .string("django-delivery"), "name": .string("Django delivery"), "description": .string("Plan, build, review."),
            "steps": .array([
                .object(["id": .string("plan"), "type": .string("agent"), "agent": .string("lead"), "next": .string("build")]),
                .object(["id": .string("build"), "type": .string("spawn"), "agent": .string("django-builder"), "next": .string("review")]),
                .object([
                    "id": .string("review"), "type": .string("agent"), "agent": .string("api-reviewer"),
                    "routes": .object(["approved": .string("end"), "changes_requested": .string("build")]),
                ]),
            ]),
        ]),
        "make_default": .bool(true),
    ])

    func proposal() throws -> SetupProposal {
        guard case .setupProposal(let proposal) = try HandoffTool.proposeSetup.decode(Self.arguments) else {
            Issue.record("propose_setup didn’t decode to a setup proposal")
            throw HandoffError.missing("setup")
        }
        return proposal
    }

    func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "saturn-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ProjectConfigLoader.installDefaults(repository: root)
        return root
    }

    @Test func theToolArgumentsDecodeWithTheWorkflowID() throws {
        let proposal = try proposal()
        #expect(proposal.specFolder == ".saturn/specs")
        #expect(proposal.agents.map(\.id) == ["django-builder", "api-reviewer"])
        #expect(proposal.agents.first?.kind == .builder)
        #expect(proposal.workflow.id == "django-delivery")
        #expect(proposal.workflow.step("build")?.profile == "django-builder")
        #expect(proposal.makeDefault)
        #expect(SetupProposal.decode(json: proposal.json) == proposal)
        #expect(HandoffTool.proposeSetup.inputSchema["required"] == .array(["mission", "spec_folder", "agents", "workflow", "make_default"].map(JSONValue.string)))
    }

    @Test func aValidProposalHasNoErrors() throws {
        #expect(try proposal().validate(against: ProjectConfig()) == [])
    }

    @Test func validationCatchesBadFoldersIDsAndWorkflows() throws {
        var bad = try proposal()
        bad.specFolder = "docs"
        bad.agents.append(bad.agents[0])
        bad.agents.append(AgentProfile(id: "builder", name: "B", kind: .builder, instructions: "x"))
        bad.agents.append(AgentProfile(id: "Big_Agent", name: "C", kind: .checker, instructions: "y"))
        bad.workflow.steps[2].routes["changes_requested"] = WorkflowRoute(to: "nowhere")
        bad.workflow.steps.append(WorkflowStep(id: "qa", type: .agent, profile: "ghost"))

        let errors = bad.validate(against: ProjectConfig())
        #expect(errors.contains("spec_folder must be “spec” or “.saturn/specs”, not “docs”"))
        #expect(errors.contains("agent id “django-builder” is used more than once"))
        #expect(errors.contains("agent “builder”: “builder” is reserved for the built-in agent kinds"))
        #expect(errors.contains("agent “Big_Agent”: “Big_Agent” must be lowercase kebab-case, like django-builder"))
        #expect(errors.contains("workflow: steps.review: routes to unknown step “nowhere”"))
        #expect(errors.contains("workflow: steps.qa: agent “ghost” isn’t lead, builder, checker or an agent profile in .saturn/agents"))

        var unnamed = try proposal()
        unnamed.workflow.id = ""
        #expect(unnamed.validate(against: ProjectConfig()) == ["workflow: needs an id in lowercase kebab-case, like django-delivery"])
    }

    @Test func aWrongKindIsReportedAsAToolError() {
        guard case .object(var arguments) = Self.arguments else { return }
        arguments["agents"] = .array([.object(["id": .string("x"), "name": .string("X"), "kind": .string("lead"), "description": .string(""), "instructions": .string("i")])])
        #expect(throws: HandoffError.self) { try HandoffTool.proposeSetup.decode(.object(arguments)) }
    }

    @Test func filesListsEveryFileAndMarksOverwrites() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let files = try proposal().files(in: repository, onboardingVersion: 1, now: Date(timeIntervalSince1970: 0))
        #expect(files.map(\.path) == [
            ".saturn/specs/mission.md", ".saturn/specs.yaml", ".saturn/agents/django-builder.yaml", ".saturn/agents/api-reviewer.yaml",
            ".saturn/workflows/django-delivery.yaml", ".saturn/project.yaml", ".saturn/onboarding.yaml",
        ])
        #expect(files.filter(\.overwrites).map(\.path) == [])
        #expect(files[1].contents == "folder: .saturn/specs\n")
        #expect(files.last?.contents == "version: 1\ncompleted_at: '1970-01-01T00:00:00Z'\n")

        try ProjectConfigLoader.write(ProjectPreferences(defaultWorkflow: "feature-delivery"), repository: repository)
        #expect(try proposal().files(in: repository).filter(\.overwrites).map(\.path) == [".saturn/project.yaml"])
        #expect(!FileManager.default.fileExists(atPath: repository.appending(path: ".saturn/specs/mission.md").path))
    }

    @Test func applyWritesTheSetupAndTheConfigFollowsIt() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let proposal = try proposal()

        try proposal.apply(to: repository, onboardingVersion: OnboardingDefinition.bundled.version)
        let config = ProjectConfigLoader.load(repository: repository)
        #expect(config.issues.isEmpty)
        #expect(config.specs.folder == ".saturn/specs")
        #expect(config.agents.map(\.id) == ["api-reviewer", "django-builder"])
        #expect(config.workflow("django-delivery")?.step("review")?.profile == "api-reviewer")
        #expect(config.workflow("feature-delivery") != nil)
        #expect(config.preferences.defaultWorkflow == "django-delivery")
        #expect(OnboardingRecord.recordedVersion(in: repository) == OnboardingDefinition.bundled.version)
        #expect(!OnboardingDefinition.bundled.needsOnboarding(repository: repository))
        #expect(try String(contentsOf: repository.appending(path: ".saturn/specs/mission.md"), encoding: .utf8).hasPrefix("# Todo"))
        #expect(SpecStore.files(in: repository, config: config.specs).map(\.relativePath) == [".saturn/specs/mission.md"])
        #expect(SpecStore.availablePath(title: "Add login", folder: config.specs.folder, repository: repository) == ".saturn/specs/add-login.md")

        var repoFolder = proposal
        repoFolder.specFolder = "spec"
        repoFolder.makeDefault = false
        let files = try repoFolder.apply(to: repository)
        #expect(!files.contains { $0.path == ".saturn/project.yaml" })
        #expect(files.first { $0.path == ".saturn/workflows/django-delivery.yaml" }?.overwrites == true)
        #expect(ProjectConfigLoader.load(repository: repository).specs.folder == "spec")
        #expect(FileManager.default.fileExists(atPath: repository.appending(path: "spec/mission.md").path))
    }

    func makeOnboarding() async throws -> (WorkflowDriverTests.Setup, LeadChat, Chat, Agent) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let chat = LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver)
        let onboarding = try await chat.openOnboarding(in: setup.project, scan: ProjectScanner.scanFiles(repository: setup.project.filesRoot))
        let lead = try #require(try setup.harness.database.leadAgent(taskId: onboarding.id!))
        return (setup, chat, onboarding, lead)
    }

    func cards(_ setup: WorkflowDriverTests.Setup, _ chat: Chat) throws -> [LeadMessage] {
        try setup.harness.database.leadMessages(taskId: chat.id!).filter { $0.kind == .setupProposal }
    }

    @Test func anInvalidProposalGoesBackToTheLeadWithoutACard() async throws {
        let (setup, _, onboarding, lead) = try await makeOnboarding()
        defer { setup.harness.cleanUp() }
        var bad = try proposal()
        bad.specFolder = "docs"

        await #expect(throws: HandoffError.self) { try await setup.driver.receive(.setupProposal(bad), from: lead.id!) }
        do {
            _ = try await setup.driver.receive(.setupProposal(bad), from: lead.id!)
        } catch {
            #expect(error.localizedDescription.contains("spec_folder must be “spec” or “.saturn/specs”, not “docs”"))
        }
        #expect(try cards(setup, onboarding).isEmpty)
    }

    @Test func aValidProposalPostsACardAndApplyWritesTheFiles() async throws {
        let (setup, chat, onboarding, lead) = try await makeOnboarding()
        defer { setup.harness.cleanUp() }
        let root = setup.project.filesRoot

        let reply = try await setup.driver.receive(.setupProposal(try proposal()), from: lead.id!)
        #expect(reply.contains("Nothing is written until they click Apply"))
        let card = try #require(try cards(setup, onboarding).first)
        #expect(card.status == .open)
        #expect(card.setupProposal == (try proposal()))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".saturn/specs/mission.md").path))
        #expect(!FileManager.default.fileExists(atPath: OnboardingRecord.file(in: root).path))

        _ = try await setup.driver.receive(.setupProposal(try proposal()), from: lead.id!)
        #expect(try cards(setup, onboarding).map(\.status) == [.dismissed, .open])
        let latest = try #require(try cards(setup, onboarding).last)

        let session = try #require(setup.harness.runtime.session(for: lead))
        try await waitUntil { !session.isRunning }
        let files = try chat.applySetup(latest, in: setup.project)
        #expect(files.count == 7)
        #expect(try cards(setup, onboarding).last?.status == .applied)
        let config = ProjectConfigLoader.load(repository: root)
        #expect(config.preferences.defaultWorkflow == "django-delivery")
        #expect(config.agents.count == 2)
        #expect(OnboardingRecord.recordedVersion(in: root) == OnboardingDefinition.bundled.version)
        let transcript = setup.harness.runtime.paths.transcript(lead.id!)
        try await waitUntil { ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "").contains("the user applied your setup") }

        #expect(throws: LeadChatError.setupClosed) { try chat.applySetup(latest, in: setup.project) }
        #expect(throws: LeadChatError.setupClosed) { try chat.dismissSetup(latest) }
    }

    @Test func dismissingLeavesTheProjectUntouched() async throws {
        let (setup, chat, onboarding, lead) = try await makeOnboarding()
        defer { setup.harness.cleanUp() }
        _ = try await setup.driver.receive(.setupProposal(try proposal()), from: lead.id!)
        let card = try #require(try cards(setup, onboarding).first)
        try chat.dismissSetup(card)
        #expect(try cards(setup, onboarding).first?.status == .dismissed)
        #expect(ProjectConfigLoader.load(repository: setup.project.filesRoot).agents.isEmpty)
    }

    @Test func theSpecCommitNoteFollowsTheChosenFolder() async throws {
        let (setup, _, _, lead) = try await makeOnboarding()
        defer { setup.harness.cleanUp() }
        try proposal().apply(to: setup.project.filesRoot)
        let note = setup.driver.specDraftReply(SpecDocument(title: "Add login"), review: SpecReviewStatus(reason: "off"), agent: lead)
        #expect(note.contains("Saturn commits it as .saturn/specs/add-login.md"))
    }
}
