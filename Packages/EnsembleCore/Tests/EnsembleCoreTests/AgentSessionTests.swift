import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct AgentSessionTests {
    @Test func spawnRunsOneTurnInItsOwnWorktree() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        let agent = session.agent
        #expect(agent.branch == "crew/dev-1/add-a-world-line-to-the")
        #expect(agent.baseBranch == "main")
        #expect(agent.worktreePath?.hasSuffix("/.crew/dev-1") == true)
        #expect(agent.costUSD == 0.01)
        #expect(agent.inputTokens == 10)
        #expect(agent.outputTokens == 5)
        #expect(agent.cacheReadTokens == 100)
        #expect(agent.cacheWriteTokens == 20)
        #expect(agent.processID == nil)
        #expect(transcriptKinds(session) == ["notice:started", "user", "assistant", "tool:Edit", "assistant", "finished"])

        let launch = try #require(harness.launches().first)
        #expect(launch.contains("--session-id \(agent.sessionId!)"))
        #expect(launch.contains("--permission-mode dontAsk"))
        #expect(launch.contains("--setting-sources project"))
        #expect(launch.contains("--model haiku"))
        #expect(launch.contains("Write(/\(realPath(of: agent.worktreeURL!))/**)"))
        #expect(realPath(of: agent.worktreeURL!).hasPrefix("/private/"))

        let usage = try await harness.database.writer.read { db in try UsageEntry.fetchAll(db) }
        #expect(usage.map(\.costUSD) == [0.01])
        #expect(usage.first?.model == "claude-fake-1")
        #expect(try harness.database.agent(id: session.id)?.status == .idle)
    }

    @Test func followUpResumesTheSameSessionAndAddsCost() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        session.send("Also add a test")
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 2 }

        #expect(harness.launches()[1].contains("--resume \(session.agent.sessionId!)"))
        #expect(abs(session.agent.costUSD - 0.02) < 0.000_001)
        #expect(session.agent.inputTokens == 20)
    }

    @Test func messagesSentDuringATurnAreQueuedUntilItEnds() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool?.name == "Bash" }

        session.send("first note")
        session.send("second note")
        #expect(session.queuedMessages == ["first note", "second note"])
        #expect(harness.launches().count == 1)

        try harness.setMode("normal")
        session.pause()
        try await waitUntil { session.agent.status == .paused }
        #expect(session.queuedMessages == ["first note", "second note"])

        session.resume()
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 3 }
        #expect(userMessages(session).suffix(2) == [AgentSession.continuePrompt, "first note\n\nsecond note"])
        #expect(session.queuedMessages.isEmpty)
    }

    @Test func pauseInterruptsTheTurnAndResumeContinues() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool?.name == "Bash" }
        #expect(session.agent.status == .working)
        #expect(session.agent.processID != nil)

        session.pause()
        try await waitUntil { session.agent.status == .paused }

        #expect(!session.isRunning)
        #expect(transcriptKinds(session).suffix(3) == ["interrupted", "finished", "notice:paused"])
        #expect(session.agent.costUSD == 0.01)
        #expect(session.canResume)

        try harness.setMode("normal")
        session.resume()
        try await waitUntil { session.agent.status == .idle }
        #expect(harness.launches().last?.contains("--resume \(session.agent.sessionId!)") == true)
        #expect(userMessages(session).last == AgentSession.continuePrompt)
    }

    @Test func stopEndsTheTurnAndRestartStartsAFreshSession() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool != nil }
        let firstSession = session.agent.sessionId

        session.stop()
        try await waitUntil { session.agent.status == .stopped }

        try harness.setMode("normal")
        session.restart()
        try await waitUntil { session.agent.status == .idle }

        #expect(session.agent.sessionId != firstSession)
        #expect(harness.launches().last?.contains("--session-id \(session.agent.sessionId!)") == true)
        #expect(userMessages(session).last == session.agent.task)
        #expect(transcriptKinds(session).contains("notice:restarted"))
    }

    @Test func restartWhileRunningStopsFirst() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool?.name == "Bash" }

        session.restart()
        try await waitUntil { harness.launches().count == 2 && session.transcript.activeTool?.name == "Bash" }

        #expect(transcriptKinds(session).contains("notice:stopped"))
        #expect(transcriptKinds(session).contains("notice:restarted"))
        #expect(harness.launches()[1].contains("--session-id"))
        session.stop()
        try await waitUntil { session.agent.status == .stopped }
    }

    @Test func takeOverAndHandBack() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool != nil }

        session.takeOver()
        try await waitUntil { session.agent.status == .takenOver }
        #expect(!session.isRunning)

        try harness.setMode("normal")
        session.handBack()
        try await waitUntil { session.agent.status == .idle }
        #expect(userMessages(session).last == AgentSession.handBackPrompt)
    }

    @Test func backgroundChildHoldingOutputDoesNotHangTheTurn() async throws {
        let harness = try await AgentHarness.make(mode: "lingering")
        defer { harness.cleanUp() }

        let session = try await harness.spawn()

        try await waitUntil(timeout: .seconds(5)) { session.agent.status == .idle }
        #expect(session.agent.costUSD == 0.01)
    }

    @Test func crashMarksTheAgentFailedWithStandardError() async throws {
        let harness = try await AgentHarness.make(mode: "crash")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()

        try await waitUntil { session.agent.status == .failed }

        #expect(session.agent.lastError == "boom: invalid api key")
        #expect(transcriptKinds(session).last == "notice:failed")
        #expect(session.canResume)
    }

    @Test func missingClaudeFailsWithoutLaunching() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        harness.runtime.claudeExecutable = nil

        let session = try await harness.spawn()

        #expect(session.agent.status == .failed)
        #expect(harness.launches().isEmpty)
    }

    @Test func quittingMarksRunningAgentsInterruptedAndTranscriptSurvives() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool != nil }

        let pid = try #require(session.agent.processID)
        harness.runtime.terminateAll()

        #expect(kill(pid, 0) != 0)
        #expect(session.agent.status == .interrupted)
        #expect(try harness.database.agent(id: session.id)?.status == .interrupted)

        let relaunched = AgentHarness.makeRuntime(database: harness.database, data: harness.data, bin: harness.bin)
        let restored = try #require(try relaunched.sessions(inProject: harness.project.id!).first)
        #expect(restored.transcript.entries.count == session.transcript.entries.count)
        #expect(restored.transcript.session?.sessionID == session.agent.sessionId)
        #expect(restored.canResume)

        try harness.setMode("normal")
        restored.resume()
        try await waitUntil { restored.agent.status == .idle }
        #expect(harness.launches().last?.contains("--resume") == true)
    }

    @Test func recoveryAfterCrashInterruptsAgentsLeftWorking() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let now = Date()
        let agent = try harness.database.insert(Agent(
            projectId: harness.project.id!, role: "claude-code", name: "Ghost",
            worktreePath: harness.repo.root.path, status: .working, processID: 999_999,
            createdAt: now, updatedAt: now
        ))

        try harness.runtime.recoverAfterLaunch()

        #expect(try harness.database.agent(id: agent.id!)?.status == .interrupted)
        #expect(try harness.database.agent(id: agent.id!)?.processID == nil)
        let session = try #require(harness.runtime.session(for: agent))
        #expect(transcriptKinds(session) == ["notice:interrupted"])
    }

    @Test func refusesDuplicateNamesAndEmptyTasks() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let session = try await harness.spawn("Dev 1")
        try await waitUntil { session.agent.status == .idle }

        await #expect(throws: AgentError.nameTaken("dev 1")) { try await harness.spawn("dev 1") }
        await #expect(throws: AgentError.emptyTask) { try await harness.spawn("Dev 2", task: "   ") }
        #expect(try await harness.repo.manager.list().count == 1)
    }

    @Test func deleteRemovesWorktreeBranchRecordAndTranscript() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        let transcript = harness.runtime.paths.transcript(session.id)
        #expect(FileManager.default.fileExists(atPath: transcript.path))

        try await harness.runtime.delete(session, in: harness.project, git: harness.repo.git, deleteBranch: true)

        #expect(try await harness.repo.manager.list().isEmpty)
        #expect(try await harness.repo.branches() == ["main"])
        #expect(try harness.database.agents(inProject: harness.project.id!).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: transcript.path))
    }

    private func transcriptKinds(_ session: AgentSession) -> [String] {
        session.transcript.entries.map { entry in
            switch entry.content {
            case .user: "user"
            case .assistant: "assistant"
            case .thinking: "thinking"
            case .tool(let tool): "tool:\(tool.name)"
            case .notice(let notice, _): "notice:\(notice.rawValue)"
            case .interrupted: "interrupted"
            case .turnFinished: "finished"
            }
        }
    }

    private func userMessages(_ session: AgentSession) -> [String] {
        session.transcript.entries.compactMap { entry in
            if case .user(let text) = entry.content { return text }
            return nil
        }
    }
}

@MainActor
@Suite struct AgentQuitTests {
    @Test func quitKillsAgentsThatIgnoreTermination() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        try harness.setMode("stubborn")
        let script = FakeClaude.script.replacingOccurrences(of: "mode=\"${FAKE_MODE:-normal}\"", with: "trap '' TERM\nmode=\"${FAKE_MODE:-normal}\"")
        try "#!/bin/sh\n\(script)\n".write(to: harness.bin.appending(path: "claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.bin.appending(path: "claude").path)
        try harness.setMode("slow")

        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool != nil }
        let pid = try #require(session.agent.processID)

        harness.runtime.terminateAll(gracePeriod: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(100))

        #expect(kill(pid, 0) != 0)
        #expect(session.agent.status == .interrupted)
    }
}
