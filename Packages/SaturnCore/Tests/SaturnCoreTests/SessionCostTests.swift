import Foundation
import GRDB
import Testing
@testable import SaturnCore

struct SessionCostTests {
    static let run50Results = [
        #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","total_cost_usd":7.391963200000003,"usage":{"input_tokens":150,"cache_creation_input_tokens":294257,"cache_read_input_tokens":17131136,"output_tokens":80554},"modelUsage":{"claude-opus-5-5":{"inputTokens":150,"outputTokens":80554,"costUSD":7.391963200000003}}}"#,
        #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","total_cost_usd":7.391963200000003,"usage":{"output_tokens_details":{"thinking_tokens":0}},"modelUsage":{"claude-opus-5-5":{"inputTokens":150,"outputTokens":80554,"costUSD":7.391963200000003}}}"#,
        #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","total_cost_usd":7.391963200000003,"usage":{"output_tokens_details":{"thinking_tokens":0}},"modelUsage":{"claude-opus-5-5":{"inputTokens":150,"outputTokens":80554,"costUSD":7.391963200000003}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":36.45682080000001,"usage":{"input_tokens":356,"cache_creation_input_tokens":761827,"cache_read_input_tokens":97921088,"output_tokens":169230},"modelUsage":{"claude-opus-5-5":{"inputTokens":506,"outputTokens":249784,"costUSD":36.45682080000001}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":37.8737676,"usage":{"input_tokens":16,"cache_creation_input_tokens":9488,"cache_read_input_tokens":6135994,"output_tokens":5689},"modelUsage":{"claude-opus-5-5":{"inputTokens":522,"outputTokens":255473,"costUSD":37.8737676}}}"#,
    ]

    static func result(_ line: String) throws -> TurnResult {
        guard case .turnCompleted(let result) = try #require(ClaudeEvent.parse(line: line).first) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return result
    }

    static func result(total: Double, turnOutput: Int, models: [String: Int]? = nil) throws -> TurnResult {
        let modelUsage = models.map { models in
            #","modelUsage":{"# + models.map { #""\#($0.key)":{"outputTokens":\#($0.value)}"# }.joined(separator: ",") + "}"
        } ?? ""
        return try result(#"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":\#(total),"usage":{"output_tokens":\#(turnOutput)}\#(modelUsage)}"#)
    }

    func agent() -> Agent {
        Agent(projectId: 1, role: "claude-code", name: "Dev", status: .idle, createdAt: .now, updatedAt: .now)
    }

    @Test func resultsReportTheSessionsCumulativeOutputTokens() throws {
        let results = try Self.run50Results.map(Self.result)
        #expect(results.map(\.processOutputTokens) == [80554, 80554, 80554, 249784, 255473])
        #expect(results.map(\.usage.output) == [80554, 0, 0, 169230, 5689])
        #expect(try Self.result(total: 0.01, turnOutput: 5).processOutputTokens == nil)
    }

    @Test func run50sResumedTurnsAreCountedOnce() throws {
        var agent = agent()
        let costs = try Self.run50Results.map { agent.addTurnCost(of: try Self.result($0), continuingProcess: false) }

        let expected = [7.3919632, 0, 0, 29.0648576, 1.4169468]
        #expect(zip(costs, expected).allSatisfy { abs($0 - $1) < 0.000_001 })
        #expect(abs(agent.costUSD - 37.8737676) < 0.000_001)
        #expect(agent.sessionOutputTokens == 255473)
    }

    @Test func aResumeThatStartsItsTotalsOverIsCountedInFull() throws {
        var agent = agent()
        _ = agent.addTurnCost(of: try Self.result(total: 0.25, turnOutput: 250, models: ["opus": 250]), continuingProcess: false)

        let cost = agent.addTurnCost(of: try Self.result(total: 0.40, turnOutput: 400, models: ["opus": 400]), continuingProcess: false)

        #expect(abs(cost - 0.40) < 0.000_001)
        #expect(abs(agent.costUSD - 0.65) < 0.000_001)
    }

    @Test func aModelSwitchKeepsTheSessionTotals() throws {
        var agent = agent()
        _ = agent.addTurnCost(of: try Self.result(total: 1.00, turnOutput: 1000, models: ["opus": 1000]), continuingProcess: false)

        let cost = agent.addTurnCost(of: try Self.result(total: 1.30, turnOutput: 300, models: ["opus": 1000, "sonnet": 300]), continuingProcess: false)

        #expect(abs(cost - 0.30) < 0.000_001)
        #expect(abs(agent.costUSD - 1.30) < 0.000_001)
    }

    @Test func withoutModelUsageEachProcessStartsItsOwnTotal() throws {
        var agent = agent()
        let costs = [
            agent.addTurnCost(of: try Self.result(total: 0.01, turnOutput: 5), continuingProcess: false),
            agent.addTurnCost(of: try Self.result(total: 0.03, turnOutput: 5), continuingProcess: true),
            agent.addTurnCost(of: try Self.result(total: 0.01, turnOutput: 5), continuingProcess: false),
        ]
        #expect(zip(costs, [0.01, 0.02, 0.01]).allSatisfy { abs($0 - $1) < 0.000_001 })
    }

    @Test func theBaselineIsSeededFromTheCurrentSessionsLastResult() throws {
        var agent = agent()
        agent.sessionId = "s-2"
        let init1 = #"{"type":"system","subtype":"init","session_id":"s-1","model":"opus","cwd":"/r"}"#
        let init2 = #"{"type":"system","subtype":"init","session_id":"s-2","model":"opus","cwd":"/r"}"#
        let notice = ClaudeEvent.noticeLine(.restarted, detail: nil)

        agent.seedSessionTotals(fromTranscript: [init1, Self.run50Results[4], notice, init2, Self.run50Results[0], init2, Self.run50Results[3], notice])

        #expect(abs(agent.sessionCostUSD - 36.4568208) < 0.000_001)
        #expect(agent.sessionOutputTokens == 249784)
        let cost = agent.addTurnCost(of: try Self.result(Self.run50Results[4]), continuingProcess: false)
        #expect(abs(cost - 1.4169468) < 0.000_001)
    }

    @Test func aSessionWithoutResultsSeedsNothing() throws {
        var agent = agent()
        agent.sessionId = "s-2"
        let init1 = #"{"type":"system","subtype":"init","session_id":"s-1","model":"opus","cwd":"/r"}"#

        agent.seedSessionTotals(fromTranscript: [init1, Self.run50Results[3]])

        #expect(!agent.hasSessionTotals)
    }

    @Test func aNewSessionStartsFromZero() throws {
        var agent = agent()
        _ = agent.addTurnCost(of: try Self.result(total: 2.00, turnOutput: 100, models: ["opus": 100]), continuingProcess: false)
        agent.startSessionTotals()

        let cost = agent.addTurnCost(of: try Self.result(total: 0.50, turnOutput: 50, models: ["opus": 50]), continuingProcess: false)

        #expect(abs(cost - 0.50) < 0.000_001)
        #expect(abs(agent.costUSD - 2.50) < 0.000_001)
    }
}

extension WorkflowDriverTests {
    @Test func aBuilderReusedForReviewFixesAddsOnlyItsNewSpend() async throws {
        let setup = try await makeSetup()
        defer { setup.harness.cleanUp() }
        try ResumedSessionCostTests.ledger(setup.harness)
        try ResumedSessionCostTests.turnCents(setup.harness, 25)
        try "".write(to: setup.harness.bin.appending(path: "reject"), atomically: true, encoding: .utf8)

        let run = try startRun(setup)
        try await waitForHold(setup, run: run, .planApproval)
        let planStep = try setup.harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try setup.engine.approvePlan(run, plan: plan)
        try await waitForHold(setup, run: run, .approval, timeout: .seconds(60))

        let agents = try setup.harness.database.agents(inProject: setup.project.id!).filter { $0.runId == run.id }
        let alphaBuilder = try #require(agents.first { $0.planTaskId != nil && $0.task == "Add alpha" })
        let alphaLaunches = setup.harness.launches().filter { $0.contains(alphaBuilder.sessionId!) }
        #expect(alphaLaunches.contains { $0.contains("--resume") })

        let close = ResumedSessionCostTests.close
        let spend = ResumedSessionCostTests.trueSpend(setup.harness)
        let usage = try await ResumedSessionCostTests.usage(setup.harness).filter { $0.runId == run.id }
        let steps = try setup.harness.database.runSteps(runId: run.id!)
        let runCost = try #require(try setup.harness.database.run(id: run.id!)).costUSD
        #expect(spend > 0)
        #expect(usage.allSatisfy { close($0.costUSD, 0.25) })
        #expect(close(usage.reduce(0) { $0 + $1.costUSD }, spend))
        #expect(close(agents.reduce(0) { $0 + $1.costUSD }, spend))
        #expect(close(steps.reduce(0) { $0 + $1.costUSD }, spend))
        #expect(close(runCost, spend))

        let builders = Set(agents.filter { $0.planTaskId != nil }.compactMap(\.id))
        let builds = steps.filter { $0.stepId == "build" }
        #expect(builds.count == 2)
        let fix = try #require(builds.last)
        let fixTurns = usage.filter { entry in
            builders.contains(entry.agentId ?? -1) && entry.recordedAt >= fix.startedAt && entry.recordedAt <= (fix.endedAt ?? .now)
        }
        #expect(!fixTurns.isEmpty)
        #expect(close(fix.costUSD, 0.25 * Double(fixTurns.count)))
    }
}

@MainActor
@Suite(.serialized) struct ResumedSessionCostTests {
    static func ledger(_ harness: AgentHarness, restoresOnResume: Bool = true) throws {
        try (restoresOnResume ? "restore" : "fresh").write(to: harness.bin.appending(path: "ledger"), atomically: true, encoding: .utf8)
    }

    static func turnCents(_ harness: AgentHarness, _ cents: Int) throws {
        try String(cents).write(to: harness.bin.appending(path: "turn-cents"), atomically: true, encoding: .utf8)
    }

    static func trueSpend(_ harness: AgentHarness) -> Double {
        let log = (try? String(contentsOf: harness.bin.appending(path: "spent.log"), encoding: .utf8)) ?? ""
        return Double(log.split(separator: "\n").compactMap { Int($0) }.reduce(0, +)) / 100
    }

    static func usage(_ harness: AgentHarness) async throws -> [UsageEntry] {
        try await harness.database.writer.read { db in try UsageEntry.order(Column("id")).fetchAll(db) }
    }

    static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_001
    }

    func runTurn(_ session: AgentSession, _ harness: AgentHarness, cents: Int, launches: Int) async throws {
        try Self.turnCents(harness, cents)
        session.send("Keep going")
        try await waitUntil { session.agent.status == .idle && harness.launches().count == launches }
    }

    @Test func resumedTurnsAddOnlyTheirOwnSpend() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try Self.ledger(harness)
        try Self.turnCents(harness, 25)

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        try await runTurn(session, harness, cents: 40, launches: 2)
        try await runTurn(session, harness, cents: 10, launches: 3)

        #expect(harness.launches().dropFirst().allSatisfy { $0.contains("--resume \(session.agent.sessionId!)") })
        #expect(Self.close(Self.trueSpend(harness), 0.75))
        #expect(Self.close(session.agent.costUSD, 0.75))
        let usage = try await Self.usage(harness)
        #expect(zip(usage.map(\.costUSD), [0.25, 0.40, 0.10]).allSatisfy(Self.close))
        #expect(usage.count == 3)
        let stored = try #require(try harness.database.agent(id: session.id))
        #expect(Self.close(stored.costUSD, 0.75))
        #expect(Self.close(stored.sessionCostUSD, 0.75))
    }

    @Test func aResumeThatDoesNotRestoreTotalsIsCountedInFull() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try Self.ledger(harness, restoresOnResume: false)
        try Self.turnCents(harness, 25)

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        try await runTurn(session, harness, cents: 40, launches: 2)
        try await runTurn(session, harness, cents: 5, launches: 3)

        #expect(Self.close(session.agent.costUSD, 0.70))
        #expect(Self.close(try await Self.usage(harness).reduce(0) { $0 + $1.costUSD }, Self.trueSpend(harness)))
    }

    @Test func aModelSwitchMidSessionIsCountedOnce() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try Self.ledger(harness)
        try Self.turnCents(harness, 30)

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        try "claude-other-2".write(to: harness.bin.appending(path: "report-model"), atomically: true, encoding: .utf8)
        try await runTurn(session, harness, cents: 20, launches: 2)
        try await runTurn(session, harness, cents: 15, launches: 3)

        #expect(Self.close(session.agent.costUSD, 0.65))
        #expect(Self.close(Self.trueSpend(harness), 0.65))
    }

    @Test func apiErrorRetriesThatReportTheRestoredTotalAddNothing() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        harness.runtime.apiRetryDelays = [.milliseconds(50), .milliseconds(50), .milliseconds(50)]
        try Self.ledger(harness)
        try Self.turnCents(harness, 50)

        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }
        try String(2).write(to: harness.bin.appending(path: "remaining"), atomically: true, encoding: .utf8)
        try harness.setMode("ratelimit")
        try Self.turnCents(harness, 20)
        session.send("Keep going")
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .idle && harness.launches().count == 4 }

        #expect(Self.close(Self.trueSpend(harness), 0.70))
        #expect(Self.close(session.agent.costUSD, 0.70))
        let usage = try await Self.usage(harness)
        #expect(zip(usage.map(\.costUSD), [0.50, 0, 0, 0.20]).allSatisfy(Self.close))
        #expect(usage.count == 4)
    }

    @Test func anInterruptedTurnAndItsResumeAreEachCountedOnce() async throws {
        let harness = try await AgentHarness.make(mode: "slow")
        defer { harness.cleanUp() }
        try Self.ledger(harness)
        try Self.turnCents(harness, 35)

        let session = try await harness.spawn()
        try await waitUntil { session.transcript.activeTool?.name == "Bash" }
        session.pause()
        try await waitUntil { session.agent.status == .paused }

        try harness.setMode("normal")
        try Self.turnCents(harness, 15)
        session.resume()
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 2 }

        #expect(Self.close(Self.trueSpend(harness), 0.50))
        #expect(Self.close(session.agent.costUSD, 0.50))
    }

    @Test func theBaselineSurvivesAnAppRestart() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try Self.ledger(harness)
        try Self.turnCents(harness, 60)
        let first = try await harness.spawn()
        try await waitUntil { first.agent.status == .idle }

        let relaunched = AgentHarness.makeRuntime(database: harness.database, data: harness.data, bin: harness.bin)
        let stored = try #require(try harness.database.agent(id: first.id))
        let session = try #require(relaunched.session(for: stored))
        try Self.turnCents(harness, 5)
        session.send("Keep going")
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 2 }

        #expect(harness.launches()[1].contains("--resume"))
        #expect(Self.close(session.agent.costUSD, 0.65))
        #expect(Self.close(try await Self.usage(harness).reduce(0) { $0 + $1.costUSD }, 0.65))
    }

    @Test func aSessionOpenBeforeTheUpgradeSeedsItsBaselineFromTheTranscript() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try Self.ledger(harness)
        try Self.turnCents(harness, 60)
        let first = try await harness.spawn()
        try await waitUntil { first.agent.status == .idle }
        try await runTurn(first, harness, cents: 30, launches: 2)

        var upgraded = try #require(try harness.database.agent(id: first.id))
        upgraded.sessionCostUSD = 0
        upgraded.sessionOutputTokens = 0
        try harness.database.save(upgraded)
        let relaunched = AgentHarness.makeRuntime(database: harness.database, data: harness.data, bin: harness.bin)
        let stored = try #require(try harness.database.agent(id: first.id))
        let session = try #require(relaunched.session(for: stored))
        #expect(!session.agent.hasSessionTotals)

        try Self.turnCents(harness, 5)
        session.send("Keep going")
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 3 }

        #expect(harness.launches()[2].contains("--resume"))
        #expect(Self.close(Self.trueSpend(harness), 0.95))
        #expect(Self.close(session.agent.costUSD, 0.95))
        #expect(Self.close(try await Self.usage(harness).reduce(0) { $0 + $1.costUSD }, 0.95))
        #expect(Self.close(session.agent.sessionCostUSD, 0.95))
    }

    @Test func aFreshSessionAfterRestartStartsItsTotalsOver() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        try Self.ledger(harness)
        try Self.turnCents(harness, 40)
        let session = try await harness.spawn()
        try await waitUntil { session.agent.status == .idle }

        try Self.turnCents(harness, 10)
        session.restart()
        try await waitUntil { session.agent.status == .idle && harness.launches().count == 2 }

        #expect(harness.launches()[1].contains("--session-id"))
        #expect(Self.close(session.agent.costUSD, 0.50))
        #expect(Self.close(session.agent.sessionCostUSD, 0.10))
    }
}
