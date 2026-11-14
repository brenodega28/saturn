import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct MultiClientTests {
    @Test func twoClientsSeeTheSameChatsAndRunsAndOnlyTheFirstAnswerWins() async throws {
        let h = try await DaemonHarness.make()
        try await h.installWorkflows()
        let first = try await h.connectedClient("first")
        let second = try await h.connectedClient("second")
        defer {
            first.stop()
            second.stop()
        }
        #expect(first.clientID != second.clientID)
        try await waitUntil { h.host.status().clients == 2 }

        let project = try await first.send(ProjectCommands.Open(path: h.repo.root.path))
        let projectID = try #require(project.id)
        let chat = try await second.send(ChatCommands.CreateEmpty(projectID: projectID, title: "Add alpha and beta", body: "Two files."))
        try await waitUntil(timeout: .seconds(1)) { (try? first.database?.task(id: chat.id!))??.title == "Add alpha and beta" }

        let run = try await first.send(RunCommands.Start(chatID: chat.id!, workflow: "feature-delivery"))
        let runID = try #require(run.id)
        func openApprovals(_ client: DaemonClient) -> [ChatRequest] {
            ((try? client.database?.openChatRequests(projectId: projectID)) ?? []).filter { $0.kind == .planApproval }
        }
        try await waitUntil(timeout: .seconds(30)) { !openApprovals(first).isEmpty && !openApprovals(second).isEmpty }
        #expect(try first.database?.run(id: runID)?.status == .waitingOnYou)
        #expect(try second.database?.run(id: runID)?.status == .waitingOnYou)

        let feed = PendingPermissionFeed(database: try #require(second.database))
        feed.start()
        defer { feed.stop() }

        let request = try #require(openApprovals(second).first)
        let planStep = try #require(try first.database?.runSteps(runId: runID).first { $0.stepId == "plan" })
        let plan = try #require(planStep.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)

        try await first.send(RunCommands.ApprovePlan(runID: runID, plan: plan, requestID: request.id))
        try await waitUntil(timeout: .seconds(1)) { openApprovals(second).isEmpty }
        #expect(try second.database?.chatRequest(id: request.id!)?.status == .answered)

        await #expect(throws: CommandFailure.alreadyAnswered("This approval")) {
            try await second.send(RunCommands.ApprovePlan(runID: runID, plan: plan, requestID: request.id))
        }

        let lead = try #require(try first.database?.agents(inProject: projectID).first { $0.role == "lead" && $0.runId == runID })
        try await waitUntil(timeout: .seconds(30)) { first.database.flatMap { try? $0.engineState(runId: runID).hold?.reason } == .approval }
        _ = try await h.host.driver.receive(.question("Which name?"), from: lead.id!)
        try await waitUntil { ((try? second.database?.openChatRequests(projectId: projectID)) ?? []).contains { $0.kind == .question } }
        let question = try #require(try second.database?.openChatRequests(projectId: projectID).first { $0.kind == .question })
        try await second.send(ApprovalCommands.AnswerQuestion(requestID: question.id!, text: "alpha"))
        await #expect(throws: CommandFailure.alreadyAnswered("This question")) {
            try await first.send(ApprovalCommands.AnswerQuestion(requestID: question.id!, text: "beta"))
        }
        try await waitUntil(timeout: .seconds(1)) { (try? first.database?.chatRequest(id: question.id!))??.response == "alpha" }

        let approval = try #require(try first.database?.openChatRequests(projectId: projectID).first { $0.kind == .approval })
        let racers = [first, second].map { client in
            Task { @MainActor () -> CommandErrorCode? in
                do {
                    _ = try await client.send(RunCommands.ResolveApproval(runID: runID, approved: true, requestID: approval.id))
                    return nil
                } catch {
                    return (error as? CommandFailure)?.code ?? .failed
                }
            }
        }
        var outcomes: [CommandErrorCode?] = []
        for racer in racers { outcomes.append(await racer.value) }
        #expect(outcomes.filter { $0 == nil }.count == 1)
        #expect(outcomes.contains(.alreadyAnswered))
        try await waitUntil(timeout: .seconds(30)) {
            (try? first.database?.run(id: runID))??.status == .succeeded && (try? second.database?.run(id: runID))??.status == .succeeded
        }
        await h.cleanUp()
    }
}

