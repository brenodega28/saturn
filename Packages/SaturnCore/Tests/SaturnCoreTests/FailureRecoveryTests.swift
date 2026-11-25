import Foundation
import Testing
@testable import SaturnCore

@Suite struct ClaudeAPIErrorParsingTests {
    @Test func parsesTheRetryAndErrorEventsClaudeCodeEmits() throws {
        let retry = ClaudeEvent.parse(line: #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":1059,"error_status":429,"error":"rate_limit","session_id":"s"}"#)
        #expect(retry == [.apiRetry(APIRetry(attempt: 2, maxRetries: 10, delayMS: 1059, status: 429, error: "rate_limit"))])

        let message = ClaudeEvent.parse(line: #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: Request rejected (429) · rate_limit_error"}]},"error":"rate_limit","is_api_error_message":true,"session_id":"s"}"#)
        #expect(message == [.apiError(ClaudeAPIError(kind: "rate_limit", message: "API Error: Request rejected (429) · rate_limit_error"))])

        let result = ClaudeEvent.parse(line: #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 529","terminal_reason":"api_error","api_error_status":529,"total_cost_usd":0,"duration_ms":3,"usage":{"input_tokens":0,"output_tokens":0},"permission_denials":[]}"#)
        guard case .turnCompleted(let turn)? = result.first else {
            Issue.record("Expected a turn result")
            return
        }
        #expect(turn.isAPIError)
        #expect(turn.apiErrorStatus == 529)
    }

    @Test func classifiesWhichErrorsAreWorthRetrying() {
        #expect(ClaudeAPIError(kind: "rate_limit", message: "").isTransient)
        #expect(ClaudeAPIError(kind: "server_error", message: "").isTransient)
        #expect(ClaudeAPIError(kind: "unknown", status: 503, message: "").isTransient)
        #expect(ClaudeAPIError(kind: "unknown", message: "").isTransient)
        #expect(!ClaudeAPIError(kind: "authentication_failed", message: "").isTransient)
        #expect(!ClaudeAPIError(kind: "billing_error", message: "").isTransient)
        #expect(!ClaudeAPIError(kind: "unknown", status: 400, message: "").isTransient)
        #expect(ClaudeAPIError(kind: "unknown", status: 429, message: "").isRateLimit)
    }
}

@MainActor
@Suite(.serialized) struct FailureRecoveryTests {
    func setRemainingFailures(_ harness: AgentHarness, _ count: Int) throws {
        try String(count).write(to: harness.bin.appending(path: "remaining"), atomically: true, encoding: .utf8)
    }

    func notices(_ session: AgentSession) -> [SaturnNotice] {
        session.transcript.entries.compactMap { entry in
            if case .notice(let notice, _) = entry.content { return notice }
            return nil
        }
    }

    @Test func aRateLimitedTurnWaitsOutTheCooldownAndContinues() async throws {
        let harness = try await AgentHarness.make(mode: "ratelimit")
        defer { harness.cleanUp() }
        harness.runtime.apiRetryDelays = [.seconds(1), .seconds(1)]
        var replies: [String] = []
        harness.runtime.observeReplies { _, reply in replies.append(reply) }

        let session = try await harness.spawn()
        try await waitUntil { session.retryingAt != nil }
        #expect(session.agent.status == .waiting)
        #expect(harness.runtime.isCoolingDown)

        try await waitUntil { session.agent.status == .idle }
        #expect(harness.launches().count == 2)
        #expect(harness.launches().last?.contains("--resume") == true)
        #expect(notices(session).contains(.retrying))
        #expect(session.agent.lastError == nil)
        #expect(!harness.runtime.isCoolingDown)
        #expect(replies == ["Done"])
    }

    @Test func theCooldownHoldsOtherAgentsBackToo() async throws {
        let harness = try await AgentHarness.make(mode: "ratelimit")
        defer { harness.cleanUp() }
        harness.runtime.apiRetryDelays = [.seconds(1)]

        let first = try await harness.spawn("Dev 1")
        try await waitUntil { first.retryingAt != nil }
        let second = try await harness.spawn("Dev 2")
        #expect(second.isQueued)
        #expect(second.retryingAt != nil)

        try await waitUntil { first.agent.status == .idle && second.agent.status == .idle }
        #expect(harness.launches().count == 3)
    }

    @Test func retriesRunOutAndTheAgentFails() async throws {
        let harness = try await AgentHarness.make(mode: "overloaded")
        defer { harness.cleanUp() }
        try setRemainingFailures(harness, 9)
        harness.runtime.apiRetryDelays = [.milliseconds(50), .milliseconds(50)]

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .failed }
        #expect(harness.launches().count == 3)
        #expect(session.agent.lastError?.contains("2 retries didn’t get through") == true)
        #expect(notices(session).filter { $0 == .retrying }.count == 2)
        #expect(session.canResume)
    }

    @Test func credentialErrorsFailRightAway() async throws {
        let harness = try await AgentHarness.make(mode: "autherror")
        defer { harness.cleanUp() }
        try setRemainingFailures(harness, 9)
        harness.runtime.apiRetryDelays = [.milliseconds(50)]

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .failed }
        #expect(harness.launches().count == 1)
        #expect(session.agent.lastError?.hasPrefix("Claude rejected the credentials") == true)
        #expect(!harness.runtime.isCoolingDown)
    }

    @Test func aCrashedTurnIsRestartedOnce() async throws {
        let harness = try await AgentHarness.make(mode: "crashonce")
        defer { harness.cleanUp() }

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 2 }
        #expect(notices(session).contains(.retrying))
        #expect(!notices(session).contains(.failed))
        #expect(harness.launches().last?.contains("--resume") == true)
    }

    @Test func aMissingWorktreeIsRestoredFromItsBranch() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        harness.runtime.gitProvider = { harness.repo.git }
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        let worktree = try #require(session.agent.worktreeURL)
        let branch = session.agent.branch

        try FileManager.default.removeItem(at: worktree)
        session.send("Add one more line")
        session.send("And a last one")

        try await waitUntil { session.agent.status == .idle && harness.launches().count == 3 }
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "README.md").path))
        #expect(try await harness.repo.git.run(["branch", "--show-current"], in: worktree).trimmingCharacters(in: .whitespacesAndNewlines) == branch)
        #expect(notices(session).filter { $0 == .restoringWorktree }.count == 1)
    }

    @Test func aMissingWorktreeWhoseBranchIsGoneFails() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        harness.runtime.gitProvider = { harness.repo.git }
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        let worktree = try #require(session.agent.worktreeURL)
        let branch = try #require(session.agent.branch)

        try await harness.repo.git.run(["worktree", "remove", "--force", worktree.path], in: harness.repo.root)
        try await harness.repo.git.run(["branch", "-D", branch], in: harness.repo.root)
        session.send("Add one more line")

        try await waitUntil { session.agent.status == .failed }
        #expect(session.agent.lastError?.contains("couldn’t be restored") == true)
        #expect(session.agent.lastError?.contains("\(branch) no longer exists") == true)
        #expect(harness.launches().count == 1)
    }
}

@MainActor
@Suite(.serialized) struct RunSetupRecoveryTests {
    @Test func aFailedSetupScriptHoldsTheRunAndRetryingTheStepRepairsIt() async throws {
        let workflow = WorkflowDriverTests()
        let setup = try await workflow.makeSetup()
        defer { setup.harness.cleanUp() }
        let projectID = try #require(setup.project.id)
        var settings = ProjectSettings()
        settings.setupScript = "test -f \"$FAKE_DIR/setup-ok\" || { echo 'npm ERR! registry unreachable'; exit 4; }"
        try setup.harness.database.updateSettings(settings, forProject: projectID)
        setup.harness.runtime.worktreePrepared = { [runtime = setup.harness.runtime] in try await runtime.runSetupScript($0) }

        let run = try workflow.startRun(setup)
        try await workflow.waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)

        try await workflow.waitForHold(setup, run: run, .stepFailed)
        let item = try #require(try setup.harness.database.openChatRequests(projectId: projectID).last)
        #expect(item.body.contains("The setup script failed in"))
        #expect(item.body.contains("npm ERR! registry unreachable"))
        #expect(item.body.contains("Settings › Workspaces"))

        try "".write(to: setup.harness.bin.appending(path: "setup-ok"), atomically: true, encoding: .utf8)
        try setup.engine.retryStep(run)
        try await workflow.waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let builders = try setup.harness.database.agents(inProject: projectID).filter { $0.runId == run.id && $0.planTaskId != nil }
        #expect(builders.count == 2)
        #expect(builders.allSatisfy { $0.status != .failed })
    }
}
