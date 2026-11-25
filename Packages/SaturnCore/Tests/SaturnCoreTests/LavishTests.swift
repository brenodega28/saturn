import Foundation
import Testing
@testable import SaturnCore

final class FakeLavish: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [LavishInvocation] = []
    private var polls: [String] = []
    var url = "http://127.0.0.1:43901/session/abc123"
    var replyOutput = #"{"reply":{"status":"sent"}}"#

    var invocations: [LavishInvocation] { lock.withLock { calls } }

    func commands(_ name: String) -> [[String]] {
        invocations.map { Array($0.arguments.dropFirst(2)) }.filter { ($0.first == name) || (name == "open" && $0.first?.hasSuffix(".html") == true) }
    }

    func queuePoll(_ json: String) {
        lock.withLock { polls.append(json) }
    }

    var launch: LavishLauncher {
        { [self] invocation in
            lock.withLock { calls.append(invocation) }
            let command = invocation.arguments.dropFirst(2).first ?? ""
            switch command {
            case "poll":
                while true {
                    if let next = lock.withLock({ polls.isEmpty ? nil : polls.removeFirst() }) {
                        return LavishProcessOutput(exitCode: 0, standardOutput: Data(next.utf8))
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            case "reply":
                return LavishProcessOutput(exitCode: 0, standardOutput: Data(replyOutput.utf8))
            case "end":
                return LavishProcessOutput(exitCode: 0, standardOutput: Data(#"{"session":{"status":"ended"}}"#.utf8))
            default:
                return LavishProcessOutput(exitCode: 0, standardOutput: Data(#"{"session":{"url":"\#(url)","status":"opened"}}"#.utf8))
            }
        }
    }

    func runtime(paths: AppPaths, environment: [String: String] = [:]) -> LavishRuntime {
        LavishRuntime(
            package: URL(fileURLWithPath: "/bundle/Lavish"), node: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            stateDirectory: paths.lavishState, baseEnvironment: environment, launch: launch
        )
    }
}

let feedbackJSON = #"{"session":{"status":"feedback"},"prompts":[{"uid":"1","prompt":"Make this measurable","selector":"li#criterion-CRITERION > span","tag":"span","text":"beta.txt exists","attachments":[{"id":"a1","path":"/tmp/shot.png"}]},{"uid":"2","prompt":"Shorter please","selector":"section#section-summary > p","tag":"p","text":"Add two text files."}]}"#

@Suite struct SpecPageRendererTests {
    let document = SpecDocument(
        title: "Alpha <and> beta", status: .draft, version: 3, workers: [SpecWorker(role: "builder", name: "Swift Dev", reason: "Builds the files")],
        summary: "Add two `text` files.", interfaces: ["alpha.txt"], outOfScope: ["Gamma"],
        acceptanceCriteria: [SpecCriterion(text: "alpha.txt exists", checked: true), SpecCriterion(text: "beta.txt exists")],
        verification: "Run `ls`"
    )

    @Test func rendersEverySectionWithStableCriterionIDs() {
        let html = SpecPageRenderer().render(document)
        #expect(html.contains("<title>Alpha &lt;and&gt; beta</title>"))
        #expect(html.contains("Version 3") && html.contains("status-draft") && html.contains("1/2 criteria met"))
        for heading in ["Summary", "Interfaces", "Out of scope", "Acceptance criteria", "Verification", "Plan &amp; approvals"] {
            #expect(html.contains("<h2>\(heading)</h2>"))
        }
        #expect(html.contains("<code>text</code>") && html.contains("Builds the files"))
        let ids = SpecPageRenderer.criterionIDs(document.acceptanceCriteria)
        #expect(ids.count == 2 && Set(ids).count == 2)
        for id in ids { #expect(html.contains("id=\"criterion-\(id)\" data-criterion=\"\(id)\"")) }
        #expect(html.components(separatedBy: "data-criterion=").count == 3)
        #expect(html.contains("class=\"checked\""))
    }

    @Test func criterionIDsSurviveRewordingCaseAndReordering() {
        #expect(SpecPageRenderer.criterionID("Beta.txt exists!") == SpecPageRenderer.criterionID("beta.txt   exists"))
        let reordered = SpecPageRenderer.criterionIDs([SpecCriterion(text: "beta.txt exists"), SpecCriterion(text: "alpha.txt exists")])
        #expect(reordered == SpecPageRenderer.criterionIDs(document.acceptanceCriteria).reversed())
        let twins = SpecPageRenderer.criterionIDs([SpecCriterion(text: "same"), SpecCriterion(text: "same")])
        #expect(twins[1] == twins[0] + "-2")
    }

    @Test func pageHasExplicitBackgroundAndDarkStyles() {
        let html = SpecPageRenderer().render(document)
        #expect(html.contains("body {") && html.contains("background: var(--page)"))
        #expect(html.contains("prefers-color-scheme: dark"))
        #expect(!html.contains("{{"))
    }

    @Test func writingADraftWritesThePageNextToIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "spec-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpecStore(paths: AppPaths(root: root))
        let url = store.draftURL(projectId: 1, taskId: 7)
        try store.write(document, to: url)
        let page = store.pageURL(projectId: 1, taskId: 7)
        #expect(page.deletingPathExtension().path == url.deletingPathExtension().path && page.pathExtension == "html")
        #expect(try String(contentsOf: page, encoding: .utf8) == SpecPageRenderer().render(document))
    }

    @Test func workerReasonsRoundTripThroughMarkdownAndDraftSpec() throws {
        let parsed = try SpecDocument(markdown: document.markdown)
        #expect(parsed.workers == [SpecWorker(role: "builder", name: "Swift Dev", reason: "Builds the files")])
        let request = try JSONDecoder().decode(SpecDraftRequest.self, from: Data(#"{"title":"T","summary":"S","acceptance_criteria":["a"],"workers":[{"role":"builder","name":"Dev","reason":" Writes code "},{"role":"qa","name":"QA"}]}"#.utf8))
        #expect(request.workers == [SpecWorker(role: "builder", name: "Dev", reason: "Writes code"), SpecWorker(role: "qa", name: "QA")])
    }
}

@Suite struct LavishRuntimeTests {
    let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/saturn-data", isDirectory: true))

    @Test func everyInvocationIsTelemetryFreeLoopbackAndUnderTheDataDirectory() async throws {
        let fake = FakeLavish()
        let inherited = ["PATH": "/usr/bin", "LAVISH_AXI_ALLOWED_HOSTS": "box.tailnet.ts.net", "LAVISH_AXI_HOST": "0.0.0.0", "LAVISH_AXI_TELEMETRY": "1"]
        let lavish = fake.runtime(paths: paths, environment: inherited)
        let page = URL(fileURLWithPath: "/tmp/saturn-data/specs/1/7.html")
        fake.queuePoll(#"{"session":{"status":"waiting"}}"#)

        let url = try await lavish.open(file: page)
        _ = try await lavish.poll(file: page, takeover: true)
        try await lavish.reply(file: page, text: "Done")
        try await lavish.end(file: page)

        #expect(url.absoluteString == fake.url)
        let calls = fake.invocations
        #expect(calls.count == 4)
        for call in calls {
            #expect(call.executable.path == "/opt/homebrew/bin/node")
            #expect(Array(call.arguments.prefix(2)) == ["/bundle/Lavish/saturn-json.mjs", "/bundle/Lavish/dist/cli.mjs"])
            #expect(call.environment["LAVISH_AXI_TELEMETRY"] == "0")
            #expect(call.environment["LAVISH_AXI_NO_OPEN"] == "1")
            #expect(call.environment["LAVISH_AXI_STATE_DIR"] == "/tmp/saturn-data/lavish")
            #expect(call.environment["LAVISH_AXI_HOST"] == "127.0.0.1")
            #expect(call.environment["LAVISH_AXI_LINK_HOST"] == "127.0.0.1")
            #expect(call.environment["LAVISH_AXI_ALLOWED_HOSTS"] == nil)
            #expect(call.environment["LAVISH_AXI_PORT"] == String(lavish.port))
            #expect(call.environment["PATH"] == "/usr/bin")
            #expect(!call.arguments.contains("--also-listen"))
        }
        #expect(calls.map { Array($0.arguments.dropFirst(2)) } == [
            [page.path, "--no-open", "--reopen"],
            ["poll", page.path, "--owner", "saturn", "--takeover"],
            ["reply", page.path, "--agent-reply", "Done"],
            ["end", page.path],
        ])
        #expect((43_870..<43_970).contains(lavish.port))
        #expect(lavish.port == fake.runtime(paths: paths).port)
    }

    @Test func pollParsesFeedbackEndedAndDisconnected() async throws {
        let fake = FakeLavish()
        let lavish = fake.runtime(paths: paths)
        let page = URL(fileURLWithPath: "/tmp/p.html")
        fake.queuePoll(feedbackJSON)
        fake.queuePoll(#"{"session":{"status":"ended","ended_by":"user"}}"#)
        fake.queuePoll(#"{"session":{"status":"browser_disconnected"}}"#)
        guard case .feedback(let prompts, let ended) = try await lavish.poll(file: page) else { Issue.record("no feedback"); return }
        #expect(!ended && prompts.count == 2)
        #expect(prompts[0].prompt == "Make this measurable" && prompts[0].attachments.first?.path == "/tmp/shot.png")
        #expect(try await lavish.poll(file: page) == .ended)
        #expect(try await lavish.poll(file: page) == .browserDisconnected)
    }

    @Test func errorsMapToTypedFailures() async throws {
        let fake = FakeLavish()
        let lavish = fake.runtime(paths: paths)
        fake.queuePoll(#"{"error":"Lavish Editor already has an active poll listener","code":"LISTENER_ACTIVE"}"#)
        await #expect(throws: LavishError.listenerActive) { try await lavish.poll(file: URL(fileURLWithPath: "/tmp/p.html")) }
        fake.replyOutput = #"{"error":"Lavish Editor session has ended; reply was not sent","code":"SESSION_ENDED"}"#
        await #expect(throws: LavishError.failed(code: "SESSION_ENDED", message: "Lavish Editor session has ended; reply was not sent")) {
            try await lavish.reply(file: URL(fileURLWithPath: "/tmp/p.html"), text: "hi")
        }
    }

    @Test func locatingFailsClearlyWithoutNodeOrPackage() {
        let empty = ToolLocator(searchDirectories: [URL(fileURLWithPath: "/nonexistent")])
        #expect(throws: LavishError.nodeMissing) { try LavishRuntime.locate(paths: paths, environment: [:], package: URL(fileURLWithPath: "/x"), locator: empty) }
        let homebrew = ToolLocator(environment: ["PATH": "/nonexistent"], homeDirectory: URL(fileURLWithPath: "/nonexistent"))
        #expect(homebrew.searchDirectories.map(\.path).contains("/opt/homebrew/bin"))
        #expect(throws: LavishError.packageMissing) { try LavishRuntime.locate(paths: paths, environment: [:], package: nil) }
    }

    @Test func bundledPackageIsPinnedAndShipsItsRuntime() throws {
        let package = try #require(LavishRuntime.bundledPackage)
        let manifest = try JSONDecoder().decode(LavishRuntime.Manifest.self, from: Data(contentsOf: package.appending(path: "package.json")))
        #expect(manifest.version == LavishRuntime.version)
        for file in ["saturn-json.mjs", "dist/cli.mjs", "node_modules/express/package.json", "node_modules/@toon-format/toon/package.json"] {
            #expect(FileManager.default.fileExists(atPath: package.appending(path: file).path), "\(file)")
        }
        #expect(LavishRuntime.requiredNodeMajor == 22)
    }

    @Test func nodeWarningCoversMissingAndOldNode() {
        let node = URL(fileURLWithPath: "/usr/local/bin/node")
        #expect(EnvironmentReport.nodeWarning(.missing, required: 22)?.contains("isn’t installed") == true)
        #expect(EnvironmentReport.nodeWarning(.found(path: node, version: "20.11.1"), required: 22)?.contains("older") == true)
        #expect(EnvironmentReport.nodeWarning(.found(path: node, version: "22.3.0"), required: 22) == nil)
        #expect(EnvironmentReport.nodeWarning(nil, required: 22) == nil)
        let report = EnvironmentReport(git: .missing, claude: .missing, provider: .notChosen, node: .missing)
        #expect(report.nodeWarning != nil && !report.isReady)
    }
}

@Suite struct SpecFeedbackTests {
    let document = SpecDocument(
        title: "Alpha and beta", version: 2,
        summary: "Add two text files.",
        acceptanceCriteria: [SpecCriterion(text: "alpha.txt exists"), SpecCriterion(text: "beta.txt exists")]
    )

    func prompts() throws -> [LavishPrompt] {
        let id = SpecPageRenderer.criterionID("beta.txt exists")
        let json = feedbackJSON.replacingOccurrences(of: "CRITERION", with: id)
        struct Batch: Decodable { var prompts: [LavishPrompt] }
        return try JSONDecoder().decode(Batch.self, from: Data(json.utf8)).prompts
    }

    @Test func mapsEachNoteToItsCriterionOrSection() throws {
        let message = try #require(SpecFeedback.message(for: try prompts(), document: document))
        #expect(message.hasPrefix("Spec feedback from the review page on v2 “Alpha and beta”:"))
        #expect(message.contains("1. On criterion 2 “beta.txt exists”: Make this measurable"))
        #expect(message.contains("Attachments: /tmp/shot.png"))
        #expect(message.contains("2. On Summary: Shorter please"))
    }

    @Test func fallsBackToTheAnnotatedTextAndSkipsEmptyNotes() {
        let notes = [LavishPrompt(prompt: "Why?", selector: "main > p:nth-of-type(2)", text: "Some selected words"), LavishPrompt(prompt: "  ")]
        let message = SpecFeedback.message(for: notes, document: document)
        #expect(message?.contains("1. On “Some selected words”: Why?") == true)
        #expect(message?.contains("2.") == false)
        #expect(SpecFeedback.message(for: [LavishPrompt(prompt: "")], document: document) == nil)
        #expect(SpecFeedback.target(of: LavishPrompt(prompt: "x", selector: "body"), in: document) == .page)
    }
}

@MainActor
final class DraftLog {
    var ids: [Int64] = []
    var paths: [String] = []
}

@MainActor
@Suite(.serialized) struct SpecReviewTests {
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
        reviews.deliver = { taskId, message in try? await chat.deliverSpecFeedback(message, taskId: taskId) }
        setup.driver.specReviews = reviews
        return (setup, chat, reviews, fake)
    }

    func messages(_ setup: Setup, _ task: Chat) -> [LeadMessage] {
        (try? setup.harness.database.leadMessages(taskId: task.id!)) ?? []
    }

    @Test func draftingOpensOneListenerAndFeedbackWakesTheLead() async throws {
        let (setup, chat, reviews, fake) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let drafted = DraftLog()
        reviews.drafted = { _, taskId, path in
            drafted.ids.append(taskId)
            drafted.paths.append(path)
        }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))

        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        #expect(drafted.ids == [task.id!, task.id!])
        #expect(drafted.paths.allSatisfy { $0.hasSuffix("/\(task.id!).html") })
        let status = await reviews.status(taskId: task.id!)
        #expect(status.url == fake.url && status.reason == nil)
        try await waitUntil { fake.commands("poll").count == 1 }
        #expect(fake.commands("open").count == 1)
        #expect(fake.commands("poll").first?.contains("--owner") == true)

        let id = SpecPageRenderer.criterionID("beta.txt exists")
        fake.queuePoll(feedbackJSON.replacingOccurrences(of: "CRITERION", with: id).replacingOccurrences(of: "Shorter please", with: "CHAT shorter please"))
        try await waitUntil { messages(setup, task).contains { $0.kind == .specFeedback } }
        let feedback = messages(setup, task).filter { $0.kind == .specFeedback }
        #expect(feedback.count == 1)
        #expect(feedback[0].text.contains("On criterion 2 “beta.txt exists”: Make this measurable"))
        try await waitUntil { messages(setup, task).filter { $0.kind == .lead }.count == 2 }
        let sent = setup.harness.runtime.session(for: lead)?.transcript.entries.compactMap { entry -> String? in
            if case .user(let text) = entry.content { return text }
            return nil
        } ?? []
        #expect(sent.last?.contains("Spec feedback from the review page") == true)
        #expect(sent.last?.contains(HandoffTool.replySpec.qualifiedName) == true)
        try await waitUntil { fake.commands("poll").count == 2 }
        #expect(reviews.sessions[task.id!]?.isListening == true)
    }

    @Test func replySpecPostsToTheOpenSessionAndOnlyTheLeadHasIt() async throws {
        let (setup, chat, reviews, fake) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        #expect(setup.driver.tools(for: lead).contains(.replySpec))

        await #expect(throws: HandoffError.self) { try await setup.driver.receive(.replySpec("Thanks"), from: lead.id!) }
        #expect(fake.commands("reply").isEmpty)

        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        let reply = try await setup.driver.receive(.replySpec("Made criterion 2 measurable."), from: lead.id!)
        #expect(reply.contains("marked done"))
        #expect(fake.commands("reply").last == ["reply", SpecStore(paths: setup.harness.runtime.paths).pageURL(projectId: setup.project.id!, taskId: task.id!).path, "--agent-reply", "Made criterion 2 measurable."])

        #expect(throws: HandoffError.missing("text")) { try HandoffTool.replySpec.decode(.object(["text": .string("  ")])) }
        #expect(try HandoffTool.replySpec.decode(.object(["text": .string("Done")])) == .replySpec("Done"))
        #expect(HandoffTool.replySpec.inputSchema["required"] == .array([.string("text")]))
    }

    @Test func startingTheRunEndsTheSessionAndRestartResumesWithTakeover() async throws {
        let (setup, chat, reviews, fake) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT-PROPOSE alpha and beta", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .proposal } }
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        try await waitUntil { fake.commands("poll").count == 1 }

        reviews.stopListening()
        let restarted = SpecReviews(paths: setup.harness.runtime.paths, database: setup.harness.database) { fake.runtime(paths: setup.harness.runtime.paths) }
        defer { restarted.stopListening() }
        await restarted.resume()
        try await waitUntil { fake.commands("poll").count == 2 }
        #expect(fake.commands("poll").last?.contains("--takeover") == true)
        setup.driver.specReviews = restarted

        let run = try await chat.start(try #require(messages(setup, task).first { $0.kind == .proposal }), in: setup.project)
        try await waitUntil { fake.commands("end").count == 1 }
        #expect(restarted.sessions[task.id!] == nil)
        let status = await restarted.status(taskId: task.id!)
        #expect(status.url == nil && status.reason == SpecReviewError.committed.localizedDescription)
        try await WorkflowDriverTests().waitForHold(setup, run: run, .planApproval)
    }

    @Test func remoteProjectsAndMissingNodeFallBackWithAReason() async throws {
        let (setup, chat, reviews, _) = try await make()
        defer { reviews.stopListening(); setup.harness.cleanUp() }
        let task = try await chat.createRequest("CHAT hi", in: setup.project)
        try await waitUntil { messages(setup, task).contains { $0.kind == .lead } }
        #expect(await reviews.status(taskId: task.id!).reason == SpecReviewError.noDraft.localizedDescription)
        let lead = try #require(try setup.harness.database.leadAgent(taskId: task.id!))
        reviews.makeRuntime = { throw LavishError.nodeMissing }
        _ = try await setup.driver.receive(.draftSpec(request), from: lead.id!)
        #expect(await reviews.status(taskId: task.id!).reason == LavishError.nodeMissing.localizedDescription)
        #expect(FileManager.default.fileExists(atPath: SpecStore(paths: setup.harness.runtime.paths).pageURL(projectId: setup.project.id!, taskId: task.id!).path))
    }
}
