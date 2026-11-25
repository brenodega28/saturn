import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct SpecCardTests {
    typealias Setup = WorkflowDriverTests.Setup

    let request = SpecDraftRequest(
        title: "Alpha and beta files", summary: "Add two text files.",
        acceptanceCriteria: ["alpha.txt exists", "beta.txt exists"], verification: "ls",
        workers: [SpecWorker(role: "builder", name: "Builder", reason: "Writes both files")]
    )

    func make() async throws -> (Setup, LeadChat, SpecReviews, FakeLavish) {
        let setup = try await WorkflowDriverTests().makeSetup()
        let chat = LeadChat(runtime: setup.harness.runtime, engine: setup.engine, driver: setup.driver)
        let fake = FakeLavish()
        let paths = setup.harness.runtime.paths
        let reviews = SpecReviews(paths: paths, database: setup.harness.database) { fake.runtime(paths: paths) }
        setup.driver.specReviews = reviews
        return (setup, chat, reviews, fake)
    }

    func cards(_ setup: Setup, _ task: Chat) -> [LeadMessage] {
        ((try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []).filter { $0.kind == .specDraft }
    }

    func leadChat(_ setup: Setup, _ chat: LeadChat, text: String = "CHAT hi", waitFor kind: LeadMessageKind = .lead) async throws -> (Chat, Agent) {
        let task = try await chat.createRequest(text, in: setup.project)
        try await waitUntil { ((try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []).contains { $0.kind == kind } }
        return (task, try #require(try setup.harness.database.leadAgent(taskId: task.id!)))
    }

    func draft(_ setup: Setup, _ task: Chat) throws -> SpecDocument? {
        try SpecStore(paths: setup.harness.runtime.paths).draft(projectId: setup.project.id!, taskId: task.id!)
    }

    @Test func everyDraftPostsACardAndSupersedesTheOlderOnes() async throws {
        let (setup, chat, reviews, fake) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let (task, lead) = try await leadChat(setup, chat)

        let first = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        #expect(first.contains("The page is open in Lavish") && first.contains(HandoffTool.replySpec.qualifiedName))
        var revised = request
        revised.title = "Alpha, beta and gamma"
        revised.acceptanceCriteria.append("gamma.txt exists")
        _ = try await setup.driver.receive(.draftSpec(revised), from: lead.id!)

        let posted = cards(setup, task)
        #expect(posted.map(\.status) == [.dismissed, .open])
        #expect(posted.map(\.title) == ["Alpha and beta files", "Alpha, beta and gamma"])
        #expect(posted.map { $0.specDraft?.version } == [1, 2])
        #expect(posted.map { $0.specDraft?.criteria } == [2, 3])
        #expect(posted.allSatisfy { $0.specDraft?.url == fake.url && $0.specDraft?.reason == nil })
        #expect(try setup.harness.database.openSpecDraft(taskId: task.id!)?.id == posted.last?.id)

        let read = try ChatReader(database: setup.harness.database, paths: setup.harness.runtime.paths)
            .read(ChatReadRequest(requestID: task.id!, section: .messages))
        #expect(read.contains("Spec v2 “Alpha, beta and gamma” · 3 acceptance criteria · review page \(fake.url)"))
    }

    @Test func aLavishFailureShowsOnTheCardAndInTheToolResult() async throws {
        let (setup, chat, reviews, _) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let (task, lead) = try await leadChat(setup, chat)
        reviews.makeRuntime = { throw LavishError.nodeMissing }

        let reply = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        let reason = LavishError.nodeMissing.localizedDescription
        #expect(reply.contains("The Lavish review page did not open: \(reason)"))
        #expect(!reply.contains("The page is open in Lavish"))
        let card = try #require(cards(setup, task).last?.specDraft)
        #expect(card.url == nil && card.reason == reason)
    }

    @Test func reviewStatusCarriesThePortAndRewritesItForATunnel() {
        let status = SpecReviewStatus(url: "http://127.0.0.1:43901/session/abc123")
        #expect(status.port == 43901)
        let forwarded = status.forwarded(to: 51234)
        #expect(forwarded.url == "http://127.0.0.1:51234/session/abc123" && forwarded.port == 43901)
        #expect(SpecReviewStatus(reason: "No Node").port == nil)
        let decoded = try? JSONDecoder().decode(SpecReviewStatus.self, from: Data(#"{"url":"http://127.0.0.1:9/x"}"#.utf8))
        #expect(decoded?.port == nil && decoded?.url == "http://127.0.0.1:9/x")
        #expect(decoded?.lavishPort == 9)
        #expect(decoded?.forwarded(to: 51234).url == "http://127.0.0.1:51234/x")
        let portless = try? JSONDecoder().decode(SpecReviewStatus.self, from: Data(#"{"url":"http://127.0.0.1/x"}"#.utf8))
        #expect(portless?.lavishPort == nil)
        #expect(SpecReviewStatus(reason: "No Node").lavishPort == nil)
    }

    @Test func approvingWithoutAProposalStartsAFeatureDeliveryRunWithTheSpec() async throws {
        let (setup, chat, reviews, fake) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let (task, lead) = try await leadChat(setup, chat)
        await #expect(throws: SpecReviewError.noDraft) { try await chat.approveSpec(taskId: task.id!, in: setup.project) }
        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)

        let run = try await chat.approveSpec(taskId: task.id!, in: setup.project)
        #expect(run.workflow == "feature-delivery" && run.title == "Alpha and beta files")
        #expect(run.brief?.contains("Add two text files.") == true && run.brief?.contains("- beta.txt exists") == true)
        let link = try #require(SpecStore(paths: setup.harness.runtime.paths).runSpec(runId: run.id!))
        #expect(link.link.branch == RunSpecLink.branch(runId: run.id!))
        #expect(try draft(setup, task)?.status == .inProgress)
        let card = try #require(cards(setup, task).last)
        #expect(card.status == .started && card.runId == run.id)
        try await waitUntil { fake.commands("end").count == 1 }

        await #expect(throws: LeadChatError.runInProgress) { try await chat.approveSpec(taskId: task.id!, in: setup.project) }
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
    }

    @Test func approvingUsesTheOpenProposalAndRefusesACommittedSpec() async throws {
        let (setup, chat, reviews, _) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let (task, lead) = try await leadChat(setup, chat, text: "CHAT-PROPOSE alpha and beta", waitFor: .proposal)
        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)

        let run = try await chat.approveSpec(taskId: task.id!, in: setup.project)
        let proposal = try #require(try setup.harness.database.leadMessages(taskId: task.id!).first { $0.kind == .proposal })
        #expect(proposal.status == .started && proposal.runId == run.id)
        #expect(SpecStore(paths: setup.harness.runtime.paths).runSpec(runId: run.id!) != nil)
        #expect(cards(setup, task).last?.status == .started)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
        try await setup.engine.cancel(run)
        try await waitUntil { (try? setup.harness.database.run(id: run.id!))??.isActive == false }

        await #expect(throws: SpecReviewError.committed) { try await chat.approveSpec(taskId: task.id!, in: setup.project) }
        #expect(try draft(setup, task)?.status == .inProgress)
    }
}

@MainActor
final class FakeChatRouting: ChatRouting {
    var reads: [(ChatReadRequest, DaemonID)] = []

    func readChat(_ request: ChatReadRequest, on daemon: DaemonID) async throws -> String {
        reads.append((request, daemon))
        return "remote chat \(request.requestID)"
    }
}

@MainActor
@Suite(.serialized) struct ReadChatRoutingTests {
    let local = DaemonID()
    let remote = DaemonID()

    @Test func theDaemonArgumentDecodesAndRejectsGarbage() throws {
        let id = remote.uuidString.lowercased()
        let tool = try HandoffTool.readChat.decode(.object(["request_id": .number(96), "daemon": .string(id)]))
        #expect(tool == .readChat(ChatReadRequest(requestID: 96, daemon: remote)))
        #expect(try HandoffTool.readChat.decode(.object(["request_id": .number(96)])) == .readChat(ChatReadRequest(requestID: 96)))
        #expect(throws: HandoffError.self) { try HandoffTool.readChat.decode(.object(["request_id": .number(96), "daemon": .string("macserver")])) }
        guard case .object(let schema) = HandoffTool.readChat.inputSchema, case .object(let properties) = schema["properties"] else {
            Issue.record("read_chat has no properties")
            return
        }
        #expect(properties["daemon"] != nil)
    }

    @Test func localOrMissingDaemonReadsThisDatabaseAndOthersGoToTheRouter() async throws {
        let setup = try await WorkflowDriverTests().makeSetup()
        defer { setup.harness.cleanUp() }
        let now = Date()
        let task = try setup.harness.database.insert(Chat(projectId: setup.project.id!, title: "Local chat", body: "", source: .chat, status: .incoming, createdAt: now, updatedAt: now))
        let routing = FakeChatRouting()
        setup.driver.daemonID = local
        setup.driver.chatRouting = routing

        #expect(try await setup.driver.readChat(ChatReadRequest(requestID: task.id!)).contains("Local chat"))
        #expect(try await setup.driver.readChat(ChatReadRequest(requestID: task.id!, daemon: local)).contains("Local chat"))
        #expect(routing.reads.isEmpty)
        #expect(try await setup.driver.readChat(ChatReadRequest(requestID: 96, daemon: remote)) == "remote chat 96")
        #expect(routing.reads.map(\.1) == [remote])

        setup.driver.chatRouting = nil
        await #expect(throws: ChatReaderError.daemonNotConnected(remote, connected: [])) {
            try await setup.driver.readChat(ChatReadRequest(requestID: 96, daemon: remote))
        }
    }

    @Test func theRelayNamesAnUnknownDaemonAndTimesOut() async throws {
        var posted: [DaemonEvent] = []
        let relay = ChatRelay { event in
            posted.append(event)
            return true
        }
        relay.peers = [DaemonPeer(id: local, name: "macserver")]
        do {
            _ = try await relay.readChat(ChatReadRequest(requestID: 96, daemon: remote), on: remote)
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains(remote.uuidString.lowercased()))
            #expect(error.localizedDescription.contains("macserver (\(local.uuidString.lowercased()))"))
        }
        #expect(posted.isEmpty)

        relay.peers = [DaemonPeer(id: remote, name: "studio")]
        relay.timeout = .milliseconds(50)
        await #expect(throws: ChatReaderError.daemonDidNotAnswer(remote, name: "studio")) {
            try await relay.readChat(ChatReadRequest(requestID: 96), on: remote)
        }
        #expect(posted.count == 1)

        let offline = ChatRelay { _ in false }
        offline.peers = [DaemonPeer(id: remote, name: "studio")]
        await #expect(throws: ChatReaderError.daemonNotConnected(remote, connected: [])) {
            try await offline.readChat(ChatReadRequest(requestID: 96), on: remote)
        }
    }

    @Test func aConnectedClientRelaysTheReadToTheOtherDaemon() async throws {
        let h = try await DaemonHarness.make()
        let client = try await h.connectedClient()
        defer { client.stop() }
        let remote = remote
        client.onEvent = { event in
            guard case .readChat(let relayID, let daemon, let request) = event else { return }
            Task {
                let answer = daemon == remote
                    ? RelayedChat(relayID: relayID, daemon: daemon, text: "chat \(request.requestID) from studio")
                    : RelayedChat(relayID: relayID, daemon: daemon, error: "unknown")
                _ = try await client.send(ChatCommands.AnswerRelay(answer: answer))
            }
        }
        try await client.send(ChatCommands.SetPeers(peers: [DaemonPeer(id: remote, name: "studio"), DaemonPeer(id: h.host.identity.id, name: "self")]))
        #expect(h.host.chatRelay.peers == [DaemonPeer(id: remote, name: "studio")])

        let text = try await h.host.driver.readChat(ChatReadRequest(requestID: 96, daemon: remote))
        #expect(text == "chat 96 from studio")
        await #expect(throws: ChatReaderError.self) {
            try await h.host.driver.readChat(ChatReadRequest(requestID: 96, daemon: DaemonID()))
        }
        await #expect(throws: CommandFailure.self) { try await client.send(ChatCommands.Read(request: ChatReadRequest(requestID: 4242, daemon: remote))) }
        await h.cleanUp()
    }

    @Test func approveSpecCommandStartsTheRunAndRefusesClosedChats() async throws {
        let h = try await DaemonHarness.make()
        try await h.installWorkflows()
        let client = try await h.connectedClient()
        defer { client.stop() }
        let project = try await client.send(ProjectCommands.Open(path: h.repo.root.path))
        let projectID = try #require(project.id)
        let chat = try await client.send(ChatCommands.CreateEmpty(projectID: projectID, title: "Alpha", body: "Two files."))
        let store = SpecStore(paths: h.paths)
        try store.write(SpecDocument(title: "Alpha files", summary: "Add alpha.", acceptanceCriteria: [SpecCriterion(text: "alpha.txt exists")]), to: store.draftURL(projectId: projectID, taskId: chat.id!))

        let runID = try await client.send(ChatCommands.ApproveSpec(chatID: chat.id!))
        #expect(store.runSpec(runId: runID) != nil)
        #expect(try h.host.database.run(id: runID)?.title == "Alpha files")
        await #expect(throws: CommandFailure.self) { try await client.send(ChatCommands.ApproveSpec(chatID: chat.id!)) }

        let closed = try await client.send(ChatCommands.CreateEmpty(projectID: projectID, title: "Closed", body: ""))
        try h.host.database.setClosed(taskId: closed.id!, reason: .dropped, at: .now)
        do {
            _ = try await client.send(ChatCommands.ApproveSpec(chatID: closed.id!))
            Issue.record("Expected a closed-chat error")
        } catch {
            #expect(error.localizedDescription.contains("closed"))
        }
        if let run = h.host.engine.runs[runID] { try? await h.host.engine.cancel(run) }
        await h.cleanUp()
    }
}
