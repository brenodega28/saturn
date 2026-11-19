import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct DaemonTests {
    func makeChat(_ h: DaemonHarness) throws -> (Project, Chat) {
        let project = try h.host.database.openProject(at: h.repo.root)
        let now = Date()
        let chat = try h.host.database.insert(Chat(
            projectId: project.id!, title: "Replicate me", body: "", source: .chat, status: .incoming, createdAt: now, updatedAt: now
        ))
        return (project, chat)
    }

    func addMessage(_ h: DaemonHarness, chat: Chat, _ text: String) throws -> LeadMessage {
        try h.host.database.insert(LeadMessage(projectId: chat.projectId, taskId: chat.id!, kind: .lead, text: text, createdAt: .now))
    }

    func replicaMessages(_ client: DaemonClient, chat: Chat) -> [String] {
        ((try? client.database?.leadMessages(taskId: chat.id!)) ?? []).map(\.text)
    }

    @Test func serveTakesTheLockAcceptsAClientAndASecondServeRefuses() async throws {
        let data = DaemonTestPaths.shortDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let executable = DaemonTestPaths.ensembledExecutable
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let first = Process()
        first.executableURL = executable
        first.arguments = ["serve", "--data-dir", data.path]
        first.standardError = FileHandle.nullDevice
        try first.run()
        defer { if first.isRunning { first.terminate() } }

        let socket = AppPaths(root: data).daemonSocket
        try await waitUntil(timeout: .seconds(20)) { FileManager.default.fileExists(atPath: socket.path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let lock = try String(contentsOf: InstanceLock.lockFile(in: AppPaths(root: data)), encoding: .utf8)
        #expect(lock.trimmingCharacters(in: .whitespacesAndNewlines) == "\(first.processIdentifier)")

        let client = DaemonClient(transport: .socket(socket), replicasDirectory: data.appending(path: "client"))
        client.start()
        defer { client.stop() }
        try await client.waitUntilConnected(timeout: .seconds(20))
        #expect(client.snapshotsReceived == 1)
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(contentsOf: AppPaths(root: data).daemonIdentity))
        #expect(client.identity == identity)
        let status = try await client.send(SettingsCommands.Status())
        #expect(status.pid == first.processIdentifier)
        try await waitUntil { client.live.mcpReady }

        let second = Process()
        second.executableURL = executable
        second.arguments = ["serve", "--data-dir", data.path]
        let errors = Pipe()
        second.standardError = errors
        try second.run()
        second.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(second.terminationStatus == 75)
        #expect(message.contains("already"))
        #expect(first.isRunning)

        first.terminate()
        first.waitUntilExit()
        #expect(first.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }

    @Test func aSecondHostOnTheSameDataDirectoryIsRefused() async throws {
        let h = try await DaemonHarness.make()
        let paths = h.paths
        await #expect(throws: InstanceLockError.self) {
            _ = try await EnsembleHost.start(paths: paths, secrets: InMemorySecretStore(), options: HostOptions(listens: false))
        }
        await h.cleanUp()
    }

    @Test func startingAHostRecoversAgentsAndRunsLeftByAPreviousProcess() async throws {
        let data = DaemonTestPaths.shortDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let paths = AppPaths(root: data)
        let seeded = try AppDatabase.open(at: paths.database)
        let project = try seeded.openProject(at: repo.root)
        let now = Date()
        let chat = try seeded.insert(Chat(projectId: project.id!, title: "Left over", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now))
        let agent = try seeded.insert(Agent(
            projectId: project.id!, role: AgentKind.builder.rawValue, name: "Builder 1", status: .working, processID: 999_999, createdAt: now, updatedAt: now
        ))
        let workflow = WorkflowDefinition(id: "tiny", name: "Tiny", steps: [WorkflowStep(id: "build", type: .agent, agent: .builder)])
        let scripted = ScriptedWorkflowDriver()
        scripted.script("build", .hang)
        let dying = RunEngine(database: seeded, driver: scripted)
        let run = try dying.start(task: chat, workflow: workflow, project: project)
        try await waitUntil { scripted.agentCalls.count == 1 }
        _ = try await seeded.writer.write { db in
            var ghost = Run(projectId: project.id!, taskId: chat.id!, workflow: "ghost", status: .running, startedAt: now)
            try ghost.insert(db)
        }

        let host = try await EnsembleHost.start(paths: paths, secrets: InMemorySecretStore(), options: HostOptions(listens: false, runsBackgroundLoops: false))
        #expect(try host.database.agent(id: agent.id!)?.status == .interrupted)
        #expect(host.engine.runs[run.id!] != nil)
        #expect(host.launchProblems.contains { $0.contains("recover") })
        #expect(host.live.mcpReady)
        await host.stop()
    }

    @Test func aDataFolderFromBeforeTheDaemonKeepsItsProjectsChatsAndRuns() async throws {
        let data = DaemonTestPaths.shortDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let repo = try await TestRepository.make()
        defer { repo.delete() }
        let paths = AppPaths(root: data)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let legacy = try DatabasePool(path: paths.database.path, configuration: configuration)
        try AppDatabase.migrator.migrate(legacy, upTo: "v25-chat-state")
        let now = Date()
        let (projectID, chatID, runID) = try await legacy.write { db -> (Int64, Int64, Int64) in
            var project = Project(name: "Legacy", path: repo.root.path, isOpen: true, createdAt: now, lastOpenedAt: now)
            try project.insert(db)
            try db.execute(
                sql: "INSERT INTO task (projectId, title, body, source, status, labels, createdAt, updatedAt) VALUES (?, 'Old chat', '', 'chat', 'done', '[]', ?, ?)",
                arguments: [project.id!, now, now]
            )
            let chatID = db.lastInsertedRowID
            var run = Run(projectId: project.id!, taskId: chatID, workflow: "feature-delivery", status: .succeeded, startedAt: now, endedAt: now, title: "Old run")
            try run.insert(db)
            var message = LeadMessage(projectId: project.id!, taskId: chatID, kind: .lead, text: "Done before the update", createdAt: now)
            try message.insert(db)
            return (project.id!, chatID, run.id!)
        }
        try legacy.close()

        let host = try await EnsembleHost.start(paths: paths, secrets: InMemorySecretStore(), options: HostOptions(runsBackgroundLoops: false))
        let client = DaemonClient(transport: .socket(paths.daemonSocket), replicasDirectory: DaemonTestPaths.shortDirectory("ec"))
        client.start()
        try await client.waitUntilConnected()
        #expect(try client.database?.openProjects().map(\.id) == [projectID])
        #expect(try client.database?.task(id: chatID)?.title == "Old chat")
        #expect(try client.database?.run(id: runID)?.title == "Old run")
        #expect(try client.database?.leadMessages(taskId: chatID).map(\.text) == ["Done before the update"])
        client.stop()
        await host.stop()
    }

    @Test func versionPrintsTheProtocolAndBuild() async throws {
        let process = Process()
        process.executableURL = DaemonTestPaths.ensembledExecutable
        process.arguments = ["version"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let info = try JSONDecoder().decode([String: String].self, from: output.fileHandleForReading.readDataToEndOfFile())
        #expect(info["protocolVersion"] == "\(EnsembleProtocol.version)")
        #expect(info["buildVersion"] == EnsembleProtocol.buildVersion)
    }

    @Test func theReplicaSeesMessagesStepsAndPermissionsWithinASecond() async throws {
        let h = try await DaemonHarness.make()
        let (project, chat) = try makeChat(h)
        let client = try await h.connectedClient()
        defer { client.stop() }
        #expect(client.snapshotsReceived == 1)
        #expect(client.database?.isReplica == true)
        #expect(try client.database?.openProjects().map(\.path) == [project.path])
        #expect(throws: (any Error).self) { try client.database?.renameProject(id: project.id!, to: "Nope") }

        let feed = PendingPermissionFeed(database: client.database!)
        feed.start()

        let message = try addMessage(h, chat: chat, "Hello from the daemon")
        let clock = ContinuousClock()
        var start = clock.now
        try await waitUntil(timeout: .seconds(1)) { replicaMessages(client, chat: chat) == [message.text] }
        print("message replicated in \(clock.now - start)")

        let run = try await h.host.database.writer.write { db -> Run in
            var run = Run(projectId: project.id!, taskId: chat.id!, workflow: "feature-delivery", status: .running, startedAt: .now)
            try run.insert(db)
            return run
        }
        start = clock.now
        let step = try h.host.database.insert(RunStep(runId: run.id!, stepId: "build", status: .running, startedAt: .now))
        try await waitUntil(timeout: .seconds(1)) { (try? client.database?.runSteps(runId: run.id!))??.map(\.status) == [.running] }
        try await h.host.database.writer.write { db in
            var finished = step
            finished.status = .succeeded
            finished.outcome = "done"
            try finished.update(db)
        }
        try await waitUntil(timeout: .seconds(1)) { (try? client.database?.runSteps(runId: run.id!))??.first?.outcome == "done" }
        print("run step replicated in \(clock.now - start)")

        start = clock.now
        try await h.host.database.writer.write { db in
            var request = PermissionRequest(
                projectId: project.id!, agentId: 1, runId: run.id, taskId: chat.id, capability: .network, request: "curl example.com",
                status: .pending, createdAt: .now
            )
            try request.insert(db)
            var card = LeadMessage(
                projectId: project.id!, taskId: chat.id!, kind: .permission, text: "curl example.com", title: "Builder 1", runId: run.id,
                createdAt: .now, permissionRequestId: request.id, permissionStatus: .pending, capability: .network
            )
            try card.insert(db)
        }
        try await waitUntil(timeout: .seconds(1)) { feed.count(projectId: project.id!) == 1 }
        print("pending permission replicated in \(clock.now - start)")
        feed.stop()
        await h.cleanUp()
    }

    @Test func aReconnectingClientResumesFromItsSequenceNumber() async throws {
        let h = try await DaemonHarness.make(retention: 5)
        let (_, chat) = try makeChat(h)
        let client = try await h.connectedClient()
        _ = try addMessage(h, chat: chat, "one")
        try await waitUntil { replicaMessages(client, chat: chat) == ["one"] }
        let seq = try #require(client.replica?.seq)

        client.stop()
        _ = try addMessage(h, chat: chat, "two")
        _ = try addMessage(h, chat: chat, "three")
        h.host.changeLog.waitUntilFlushed()
        client.start()
        try await client.waitUntilConnected()
        try await waitUntil { replicaMessages(client, chat: chat) == ["one", "two", "three"] }
        #expect(client.snapshotsReceived == 1)
        #expect(client.resyncsReceived == 0)
        #expect(try #require(client.replica?.seq) > seq)

        let identity = try #require(client.identity)
        client.stop()
        let relaunched = h.client("a", knownDaemon: identity)
        #expect(replicaMessages(relaunched, chat: chat) == ["one", "two", "three"])
        _ = try addMessage(h, chat: chat, "four")
        relaunched.start()
        try await relaunched.waitUntilConnected()
        try await waitUntil { replicaMessages(relaunched, chat: chat) == ["one", "two", "three", "four"] }
        #expect(relaunched.snapshotsReceived == 0)
        #expect(relaunched.resyncsReceived == 0)

        relaunched.stop()
        for index in 0..<20 {
            _ = try addMessage(h, chat: chat, "late \(index)")
        }
        h.host.changeLog.waitUntilFlushed()
        #expect(try #require(try h.host.changeLog.oldestSeq()) > (relaunched.replica?.seq ?? 0) + 1)
        relaunched.start()
        try await relaunched.waitUntilConnected()
        try await waitUntil { replicaMessages(relaunched, chat: chat).count == 24 }
        #expect(relaunched.resyncsReceived == 1)
        #expect(relaunched.snapshotsReceived == 1)
        relaunched.stop()
        await h.cleanUp()
    }

    @Test func transcriptsStreamAsFiles() async throws {
        let h = try await DaemonHarness.make()
        let client = try await h.connectedClient()
        defer { client.stop() }
        let transcript = h.paths.transcript(42)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "line one\n".write(to: transcript, atomically: true, encoding: .utf8)

        let whole = try await client.readFile(.transcript, id: "42")
        #expect(String(decoding: whole, as: UTF8.self) == "line one\n")

        var received = Data()
        let stream = client.file(.transcript, id: "42", follow: true)
        let appender = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            let handle = try FileHandle(forWritingTo: transcript)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("line two\n".utf8))
            try handle.close()
        }
        for try await chunk in stream {
            received.append(chunk)
            if String(decoding: received, as: UTF8.self).contains("line two") { break }
        }
        try await appender.value
        #expect(String(decoding: received, as: UTF8.self) == "line one\nline two\n")

        await #expect(throws: CommandFailure.self) { _ = try await client.readFile(.transcript, id: "999") }
        await h.cleanUp()
    }

    @Test func aConnectionShowsLiveAgentsAndTheirTranscripts() async throws {
        let h = try await DaemonHarness.make(mode: "normal")
        let client = try await h.connectedClient()
        let connection = DaemonConnection(client: client, replica: try #require(client.replica))
        defer { connection.stop() }
        let project = try await connection.send(ProjectCommands.Open(path: h.repo.root.path))

        let ids = try await connection.send(AgentCommands.Spawn(
            projectID: project.id!, kind: .builder, count: 1, name: "Dev", model: "haiku", skills: [], pinned: false, task: "Add a world line"
        ))
        let agentID = try #require(ids.first)
        let session = try #require(connection.session(agentID: agentID))
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .idle && !session.isRunning && session.transcript.entries.count > 2 }
        let texts = session.transcript.entries.compactMap { entry -> String? in
            if case .assistant(let text) = entry.content { return text }
            return nil
        }
        #expect(texts.contains("Done"))
        #expect(session.agent.worktreeURL != nil)

        session.send("Once more")
        try await waitUntil(timeout: .seconds(20)) {
            session.transcript.entries.contains { entry in
                if case .user(let text) = entry.content { return text == "Once more" }
                return false
            }
        }
        await h.cleanUp()
    }

    @Test func featureDeliveryRunsEndToEndThroughProtocolCommands() async throws {
        let h = try await DaemonHarness.make()
        try await h.installWorkflows()
        try "".write(to: h.bin.appending(path: "reject"), atomically: true, encoding: .utf8)
        let client = try await h.connectedClient()
        defer { client.stop() }

        let project = try await client.send(ProjectCommands.Open(path: h.repo.root.path))
        let projectID = try #require(project.id)
        try await waitUntil { (try? client.database?.openProjects())?.map(\.id) == [projectID] }
        let chat = try await client.send(ChatCommands.CreateEmpty(projectID: projectID, title: "Add alpha and beta", body: "Two files, please."))
        let run = try await client.send(RunCommands.Start(chatID: chat.id!, workflow: "feature-delivery"))
        let runID = try #require(run.id)

        func hold() -> RunHold? { (try? client.database?.engineState(runId: runID))?.hold }
        try await waitUntil(timeout: .seconds(30)) { hold()?.reason == .planApproval }

        let lead = try #require(try client.database?.agents(inProject: projectID).first { $0.role == "lead" && $0.runId == runID })
        try await waitUntil(timeout: .seconds(10)) { !client.live.agent(lead.id).isRunning }
        _ = try await h.host.driver.receive(.question("Which database?"), from: lead.id!)
        try await waitUntil { ((try? client.database?.openChatRequests(projectId: projectID)) ?? []).contains { $0.kind == .question } }
        let question = try #require(try client.database?.openChatRequests(projectId: projectID).first { $0.kind == .question })
        try await client.send(ApprovalCommands.AnswerQuestion(requestID: question.id!, text: "SQLite"))
        #expect(try client.database?.chatRequest(id: question.id!)?.response == "SQLite")
        try await waitUntil(timeout: .seconds(10)) { !client.live.agent(lead.id).isRunning && !client.live.agent(lead.id).isQueued }

        let planStep = try #require(try client.database?.runSteps(runId: runID).first { $0.stepId == "plan" })
        let plan = try #require(planStep.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        #expect(plan.tasks.map(\.title) == ["Add alpha", "Add beta"])
        try await client.send(RunCommands.ApprovePlan(runID: runID, plan: plan, requestID: hold()?.requestId))

        try await waitUntil(timeout: .seconds(90)) { hold()?.reason == .approval }
        let steps = try #require(try client.database?.runSteps(runId: runID))
        #expect(steps.map(\.stepId) == ["plan", "build", "review", "build", "review", "qa", "approve"])
        let pins = try #require(try client.read { db in try Pin.fetchAll(db) })
        #expect(Set(pins.map(\.file)) == ["alpha.txt", "beta.txt"])

        try await client.send(RunCommands.ResolveApproval(runID: runID, approved: true, requestID: hold()?.requestId))
        try await waitUntil(timeout: .seconds(30)) { (try? client.database?.run(id: runID))??.status == .succeeded }

        let main = try await h.repo.git.run(["ls-tree", "--name-only", "main"], in: h.repo.root)
        #expect(main.contains("alpha.txt"))
        #expect(main.contains("beta.txt"))
        #expect(try client.database?.task(id: chat.id!)?.status == .done)
        let builder = try #require(try client.database?.agents(inProject: projectID).first { $0.planTaskId != nil })
        let transcript = try await client.readFile(.transcript, id: "\(builder.id!)")
        #expect(String(decoding: transcript, as: UTF8.self).contains("submit_result"))
        await h.cleanUp()
    }
}
