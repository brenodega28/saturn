import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct WorkflowDriverTests {
    struct Setup {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let engine: RunEngine
        let project: Project
        let config: ProjectConfig
    }

    func makeSetup(endAction: EndAction = .merge) async throws -> Setup {
        let harness = try await AgentHarness.make(mode: "workflow")
        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        var feature = try #require(ProjectConfigLoader.load(repository: harness.repo.root).workflow("feature-delivery"))
        feature.end = WorkflowEnd(action: endAction, cleanUpWorktrees: true)
        try ProjectConfigLoader.write(feature, repository: harness.repo.root)
        try await harness.repo.git.run(["add", ".ensemble"], in: harness.repo.root)
        try await harness.repo.git.run(["commit", "-m", "Add Ensemble config"], in: harness.repo.root)

        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.pollInterval = .milliseconds(20)
        let engine = RunEngine(database: harness.database, driver: driver)
        let project = try #require(try harness.database.project(id: harness.project.id!))
        return Setup(harness: harness, driver: driver, engine: engine, project: project, config: ProjectConfigLoader.load(repository: harness.repo.root))
    }

    func startRun(_ setup: Setup, title: String = "Add alpha and beta") throws -> Run {
        let now = Date()
        let task = try setup.harness.database.insert(ProjectTask(
            projectId: setup.project.id!, title: title, body: "Two files, please.", source: .chat,
            status: .incoming, createdAt: now, updatedAt: now
        ))
        return try setup.engine.start(task: task, workflow: try #require(setup.config.workflow("feature-delivery")), project: setup.project)
    }

    func waitForHold(_ setup: Setup, run: Run, _ reason: HoldReason, timeout: Duration = .seconds(30)) async throws {
        try await waitUntil(timeout: timeout) { setup.engine.holds[run.id!]?.reason == reason }
    }

    @Test func featureDeliveryRunsEndToEndWithAReviewLoop() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        try "".write(to: setup.harness.bin.appending(path: "reject"), atomically: true, encoding: .utf8)

        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)

        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        #expect(plan.tasks.map(\.title) == ["Add alpha", "Add beta"])

        try setup.engine.approvePlan(run, plan: plan)
        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let steps = try setup.harness.database.runSteps(runId: run.id!)
        #expect(steps.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve"])
        #expect(steps.filter { $0.stepId == "review" }.map(\.outcome) == ["changes_requested", "approved"])
        #expect(steps.first { $0.stepId == "qa" }?.outcome == "passed")

        let agents = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id }
        #expect(agents.filter { $0.role == "tech-lead" }.count == 1)
        #expect(agents.filter { $0.planTaskId != nil }.count == 2)
        #expect(agents.filter { $0.role == "qa-engineer" }.count == 1)

        let lead = try #require(agents.first { $0.role == "tech-lead" })
        let leadLaunches = setup.harness.launches().filter { $0.contains("You are \(lead.name),") }
        #expect(leadLaunches.count == 3)
        #expect(leadLaunches.allSatisfy { $0.contains("--session-id") && !$0.contains("--resume") })
        let leadTranscript = try String(contentsOf: setup.harness.runtime.paths.transcript(lead.id!), encoding: .utf8)
        #expect(leadTranscript.components(separatedBy: "Your last check (round 1)").count == 2)
        #expect(leadTranscript.contains("Add a second line to alpha.txt (alpha.txt)"))
        #expect(leadTranscript.contains("` was at `"))

        let alphaBuilder = try #require(agents.first { $0.planTaskId != nil && $0.task == "Add alpha" })
        let alpha = try String(contentsOf: alphaBuilder.worktreeURL!.appending(path: "alpha.txt"), encoding: .utf8)
        #expect(alpha.split(separator: "\n").count == 2)
        let betaBuilder = try #require(agents.first { $0.planTaskId != nil && $0.task == "Add beta" })
        let beta = try String(contentsOf: betaBuilder.worktreeURL!.appending(path: "beta.txt"), encoding: .utf8)
        #expect(beta.split(separator: "\n").count == 1)

        let pins = try await setup.harness.database.writer.read { db in try Pin.fetchAll(db) }
        #expect(Set(pins.map(\.file)) == ["alpha.txt", "beta.txt"])
        #expect(pins.allSatisfy { $0.runId == run.id })

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }

        let main = try await setup.harness.repo.git.run(["ls-tree", "--name-only", "main"], in: setup.harness.repo.root)
        #expect(main.contains("alpha.txt"))
        #expect(main.contains("beta.txt"))
        #expect(try await setup.harness.repo.manager.list().isEmpty)
        #expect(try setup.harness.database.task(id: run.taskId)?.status == .done)
    }

    @Test func questionsWaitForTheUsersAnswer() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let lead = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.role == "tech-lead" })

        let reply = try await setup.driver.receive(.question("Which database?"), from: lead.id!)

        #expect(reply.contains("End your turn"))
        let open = try setup.harness.database.openInboxItems(projectId: setup.project.id!).filter { $0.kind == .question }
        #expect(open.map(\.body) == ["Which database?"])
        #expect(open.first?.agentId == lead.id)
    }

    @Test func plansWithUnknownRolesAreRejectedToTheAgent() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let lead = try #require(try setup.harness.database.agents(inProject: setup.project.id!).first { $0.role == "tech-lead" })

        await #expect(throws: HandoffError.self) {
            try await setup.driver.receive(.plan(Plan(summary: "x", tasks: [PlanTask(title: "t", role: "rust-wizard")])), from: lead.id!)
        }
    }

    @Test func conflictingBranchesAreResolvedByTheBuilderAfterQAFails() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        var plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        plan.tasks = plan.tasks.map { var task = $0; task.title = "Add alpha"; return task }
        try setup.engine.approvePlan(run, plan: plan)

        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let steps = try setup.harness.database.runSteps(runId: run.id!)
        #expect(steps.filter { $0.stepId == "qa" }.map(\.outcome) == ["failed", "passed"])
        let firstQA = try #require(steps.first { $0.stepId == "qa" })
        let verdict = try #require(firstQA.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.verdict)
        #expect(verdict.issues.first?.description.contains("alpha.txt") == true)
        #expect(try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.role == "qa-engineer" }.count == 1)

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }
        let alpha = try await setup.harness.repo.git.run(["show", "main:alpha.txt"], in: setup.harness.repo.root)
        #expect(alpha.split(separator: "\n").count == 2)
        #expect(!alpha.contains("<<<<<<<"))
    }

    @Test func aBranchThatConflictsWithMainGetsMainMergedInForTheBuilderToResolve() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        try "".write(to: setup.harness.bin.appending(path: "move-main"), atomically: true, encoding: .utf8)
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)

        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let steps = try setup.harness.database.runSteps(runId: run.id!)
        #expect(steps.filter { $0.stepId == "qa" }.map(\.outcome) == ["failed", "passed"])
        let builds = steps.filter { $0.stepId == "build" }.map { $0.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.branchHeads ?? [:] }
        #expect(builds.count == 2)
        #expect(builds.allSatisfy { $0.count == 2 })
        #expect(builds[0] != builds[1])
        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }
        let alpha = try await setup.harness.repo.git.run(["show", "main:alpha.txt"], in: setup.harness.repo.root)
        #expect(alpha.contains("main moved on"))
        #expect(alpha.contains("work by"))
        #expect(!alpha.contains("<<<<<<<"))
    }

    struct MergeSetup {
        let harness: AgentHarness
        let driver: AgentWorkflowDriver
        let engine: RunEngine
        let origin: URL
        let run: Run
        let gitHub: HTTPStub

        var git: GitClient { harness.repo.git }
        var root: URL { harness.repo.root }
        static let branch = "crew/delivery-run-1/add-delivery-notes"
        static let title = "Add delivery notes"

        func head(_ ref: String = "HEAD", in directory: URL? = nil) async throws -> String {
            try await git.run(["rev-parse", ref], in: directory ?? root).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func originHead() async throws -> String {
            try await head("main", in: origin)
        }

        func localBranchExists() async throws -> Bool {
            try await git.hasCommit("refs/heads/\(Self.branch)", in: root)
        }

        func originBranchExists() async throws -> Bool {
            try await git.hasCommit("refs/heads/\(Self.branch)", in: origin)
        }

        func pushFromAnotherClone(file: String, contents: String) async throws -> String {
            let clone = harness.data.appending(path: "clone-\(UUID().uuidString)", directoryHint: .isDirectory)
            try await git.clone(origin.path, to: clone)
            try contents.write(to: clone.appending(path: file), atomically: true, encoding: .utf8)
            try await git.run(["add", file], in: clone)
            try await git.run(["commit", "-m", "Change \(file) elsewhere"], in: clone)
            try await git.run(["push", "origin", "main"], in: clone)
            return try await head(in: clone)
        }
    }

    func makeMergeSetup(pushDelivery: Bool = true) async throws -> MergeSetup {
        let harness = try await AgentHarness.make()
        let git = harness.repo.git
        let root = harness.repo.root
        let origin = harness.data.appending(path: "origin.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try await git.run(["init", "--bare", "-b", "main"], in: origin)
        try await git.run(["remote", "add", "origin", origin.path], in: root)
        try await git.run(["push", "-u", "origin", "main"], in: root)

        try await git.run(["checkout", "-b", "crew/builder/notes"], in: root)
        try "one\n".write(to: root.appending(path: "delivery.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "delivery.txt"], in: root)
        try await git.run(["commit", "-m", "Add delivery notes"], in: root)
        try "hello\nfrom the builder\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "one\ntwo\n".write(to: root.appending(path: "delivery.txt"), atomically: true, encoding: .utf8)
        try await git.run(["commit", "-am", "Extend delivery notes"], in: root)
        try await git.run(["checkout", "-b", MergeSetup.branch, "main"], in: root)
        try await git.run(["merge", "--no-ff", "--no-edit", "crew/builder/notes"], in: root)
        try await git.run(["checkout", "main"], in: root)
        try await git.run(["branch", "-D", "crew/builder/notes"], in: root)
        if pushDelivery {
            try await git.run(["push", "-u", "origin", MergeSetup.branch], in: root)
        }

        let gitHub = HTTPStub()
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { harness.repo.git }
        driver.gitHubProvider = { GitHubClient(token: "tok", session: gitHub.session) }
        let engine = RunEngine(database: harness.database, driver: driver)
        let projectId = try #require(harness.project.id)
        try harness.database.updateSettings(ProjectSettings(githubRepository: "octo/widgets"), forProject: projectId)
        let now = Date()
        let task = try harness.database.insert(ProjectTask(
            projectId: projectId, title: MergeSetup.title, body: "", source: .chat, status: .done, createdAt: now, updatedAt: now
        ))
        let run = try harness.database.insert(Run(
            projectId: projectId, taskId: try #require(task.id), workflow: "feature-delivery", status: .succeeded,
            startedAt: now, endedAt: now, title: MergeSetup.title,
            deliveryBranch: MergeSetup.branch, baseBranch: "main"
        ), state: RunEngineState())
        return MergeSetup(harness: harness, driver: driver, engine: engine, origin: origin, run: run, gitHub: gitHub)
    }

    @Test func aPullRequestEndLeavesTheDeliveryBranchWithoutOpeningAPullRequest() async throws {
        let setup = try await makeSetup(endAction: .pullRequest)
        defer { setup.harness.cleanUp() }
        let gitHub = HTTPStub()
        setup.driver.gitHubProvider = { GitHubClient(token: "tok", session: gitHub.session) }
        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))
        let mainBefore = try await setup.harness.repo.git.run(["rev-parse", "main"], in: setup.harness.repo.root)

        try setup.engine.resolveApproval(run, approved: true)
        try await waitUntil(timeout: .seconds(30)) { (try? setup.harness.database.run(id: run.id!))??.status == .succeeded }

        let finished = try #require(try setup.harness.database.run(id: run.id!))
        let delivery = try #require(finished.deliveryBranch)
        #expect(finished.pullRequestURL == nil)
        #expect(finished.baseBranch == "main")
        #expect(gitHub.requests.isEmpty)
        #expect(try await setup.harness.repo.git.hasCommit("refs/heads/\(delivery)", in: setup.harness.repo.root))
        #expect(try await setup.harness.repo.git.run(["rev-parse", "main"], in: setup.harness.repo.root) == mainBefore)
        let delivered = try await setup.harness.repo.git.run(["ls-tree", "--name-only", delivery], in: setup.harness.repo.root)
        #expect(delivered.contains("alpha.txt"))
        #expect(delivered.contains("beta.txt"))
        #expect(try await setup.harness.repo.manager.list().isEmpty)
    }

    @Test func openPullRequestPushesTheDeliveryBranchAndRecordsTheURL() async throws {
        let setup = try await makeMergeSetup(pushDelivery: false)
        defer { setup.harness.cleanUp() }
        setup.gitHub.enqueue(.json("[]"), .json(201, GitHubFixtures.pullRequest(head: MergeSetup.branch)))

        try await setup.engine.openPullRequest(setup.run)

        #expect(try await setup.originBranchExists())
        #expect(setup.gitHub.requests.map(\.method) == ["GET", "POST"])
        let body = try #require(setup.gitHub.requests.last?.jsonBody())
        #expect(body["head"] as? String == MergeSetup.branch)
        #expect(body["base"] as? String == "main")
        let run = try #require(try setup.harness.database.run(id: setup.run.id!))
        #expect(run.pullRequestURL == "https://github.com/octo/widgets/pull/9")
        #expect(run.mergedAt == nil)
    }

    @Test func openPullRequestReusesAnExistingPullRequestForTheBranch() async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        setup.gitHub.enqueue(.json("[\(GitHubFixtures.pullRequest(number: 4, head: MergeSetup.branch))]"))

        let url = try await setup.driver.openPullRequest(setup.run)

        #expect(url == "https://github.com/octo/widgets/pull/4")
        #expect(setup.gitHub.requests.map(\.method) == ["GET"])
    }

    @Test(arguments: MergeMethod.allCases)
    func mergeNowLandsTheDeliveryOnBaseAndOrigin(method: MergeMethod) async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        let elsewhere = try await setup.pushFromAnotherClone(file: "other.txt", contents: "from elsewhere\n")

        try await setup.engine.mergeDelivery(setup.run, method: method)

        let head = try await setup.head()
        #expect(try await setup.originHead() == head)
        #expect(try await setup.git.currentBranch(in: setup.root) == "main")
        #expect(try await setup.git.run(["status", "--porcelain", "--untracked-files=no"], in: setup.root).isEmpty)
        #expect(try await setup.git.run(["merge-base", "--is-ancestor", elsewhere, "HEAD"], in: setup.root).isEmpty)
        #expect(try await setup.git.run(["show", "HEAD:delivery.txt"], in: setup.root) == "one\ntwo\n")
        #expect(try await setup.git.run(["show", "HEAD:README.md"], in: setup.root) == "hello\nfrom the builder\n")
        #expect(try await setup.git.run(["show", "HEAD:other.txt"], in: setup.root) == "from elsewhere\n")
        #expect(try await setup.git.run(["show", "main:delivery.txt"], in: setup.origin) == "one\ntwo\n")

        let parents = try await setup.git.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: setup.root).split(separator: " ").count - 1
        let added = try await setup.git.run(["rev-list", "--count", "\(elsewhere)..HEAD"], in: setup.root).trimmingCharacters(in: .whitespacesAndNewlines)
        let merges = try await setup.git.run(["rev-list", "--merges", "--count", "\(elsewhere)..HEAD"], in: setup.root).trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case .mergeCommit:
            #expect(parents == 2)
            #expect(try await setup.git.run(["rev-parse", "HEAD^1"], in: setup.root).trimmingCharacters(in: .whitespacesAndNewlines) == elsewhere)
        case .squash:
            #expect(parents == 1)
            #expect(added == "1")
            #expect(try await setup.git.run(["log", "-1", "--format=%s"], in: setup.root).trimmingCharacters(in: .whitespacesAndNewlines) == MergeSetup.title)
        case .rebase:
            #expect(parents == 1)
            #expect(added == "2")
            #expect(merges == "0")
        }

        #expect(try await !setup.localBranchExists())
        #expect(try await !setup.originBranchExists())
        #expect(try await setup.harness.repo.manager.list().isEmpty)
        let run = try #require(try setup.harness.database.run(id: setup.run.id!))
        #expect(run.mergedAt != nil)
        #expect(run.outcome == "Merged \(MergeSetup.branch) into main.")
        #expect(run.pullRequestURL == nil)
        #expect(setup.gitHub.requests.isEmpty)
    }

    @Test func mergeNowWorksForADeliveryBranchThatWasNeverPushed() async throws {
        let setup = try await makeMergeSetup(pushDelivery: false)
        defer { setup.harness.cleanUp() }

        try await setup.engine.mergeDelivery(setup.run, method: .squash)

        #expect(try await setup.originHead() == setup.head())
        #expect(try await setup.git.run(["show", "main:delivery.txt"], in: setup.origin) == "one\ntwo\n")
        #expect(try await !setup.localBranchExists())
        #expect(try await !setup.originBranchExists())
        #expect(setup.gitHub.requests.isEmpty)
        #expect(try setup.harness.database.run(id: setup.run.id!)?.pullRequestURL == nil)
    }

    @Test func mergeNowRefusesWhenBaseIsNotCheckedOut() async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        try await setup.git.run(["checkout", "-b", "elsewhere"], in: setup.root)
        let before = try await setup.head()
        let originBefore = try await setup.originHead()

        await #expect(throws: WorkflowDriverError.self) { _ = try await setup.driver.mergeDelivery(setup.run, method: .mergeCommit) }

        #expect(try await setup.git.currentBranch(in: setup.root) == "elsewhere")
        #expect(try await setup.head() == before)
        #expect(try await setup.head("main") == before)
        #expect(try await setup.originHead() == originBefore)
        #expect(try await setup.localBranchExists())
        #expect(try await setup.originBranchExists())
    }

    @Test func mergeNowRefusesWhenTheWorkingTreeIsDirty() async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        try "uncommitted\n".write(to: setup.root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let before = try await setup.head()
        let originBefore = try await setup.originHead()

        await #expect(throws: WorkflowDriverError.self) { try await setup.engine.mergeDelivery(setup.run, method: .squash) }

        #expect(try await setup.head() == before)
        #expect(try await setup.originHead() == originBefore)
        #expect(try String(contentsOf: setup.root.appending(path: "README.md"), encoding: .utf8) == "uncommitted\n")
        #expect(try await setup.localBranchExists())
        #expect(try await setup.originBranchExists())
        #expect(try setup.harness.database.run(id: setup.run.id!)?.mergedAt == nil)
    }

    @Test(arguments: MergeMethod.allCases)
    func aConflictingMergeLeavesBaseWhereItWas(method: MergeMethod) async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        let elsewhere = try await setup.pushFromAnotherClone(file: "README.md", contents: "hello\nfrom elsewhere\n")
        let before = try await setup.head()

        await #expect(throws: WorkflowDriverError.self) { _ = try await setup.driver.mergeDelivery(setup.run, method: method) }

        #expect(try await setup.head() == before)
        #expect(try await setup.originHead() == elsewhere)
        #expect(try await setup.git.currentBranch(in: setup.root) == "main")
        #expect(try await setup.git.run(["status", "--porcelain", "--untracked-files=no"], in: setup.root).isEmpty)
        #expect(try await setup.localBranchExists())
        #expect(try await setup.originBranchExists())
        #expect(try await setup.harness.repo.manager.list().isEmpty)
    }

    @Test func mergeNowFallsBackToTheOriginBranchWhenTheLocalOneIsGone() async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        try await setup.git.run(["branch", "-D", MergeSetup.branch], in: setup.root)

        let summary = try await setup.driver.mergeDelivery(setup.run, method: .mergeCommit)

        #expect(summary == "Merged \(MergeSetup.branch) into main.")
        #expect(try await setup.git.run(["show", "HEAD:delivery.txt"], in: setup.root) == "one\ntwo\n")
        #expect(try await setup.originHead() == setup.head())
        #expect(try await !setup.originBranchExists())
        #expect(try await !setup.git.hasCommit("refs/remotes/origin/\(MergeSetup.branch)", in: setup.root))
    }

    @Test func mergeNowRemovesAWorktreeThatStillHoldsTheDeliveryBranch() async throws {
        let setup = try await makeMergeSetup()
        defer { setup.harness.cleanUp() }
        let worktree = try setup.harness.repo.manager.path(forAgent: "delivery-run-1")
        try await setup.harness.repo.manager.ensureExcluded()
        try await setup.git.run(["worktree", "add", worktree.path, MergeSetup.branch], in: setup.root)

        _ = try await setup.driver.mergeDelivery(setup.run, method: .rebase)

        #expect(try await setup.git.run(["show", "HEAD:delivery.txt"], in: setup.root) == "one\ntwo\n")
        #expect(try await setup.harness.repo.manager.list().isEmpty)
        #expect(try await !setup.localBranchExists())
        #expect(try await !setup.originBranchExists())
    }
}
