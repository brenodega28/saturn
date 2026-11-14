import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite struct StallReporterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aStalledWorkerIsReportedOncePerSilence() throws {
        let database = try AppDatabase.inMemory()
        let project = try database.openProject(at: URL(fileURLWithPath: "/tmp/shop-\(UUID().uuidString)"))
        let projectID = try #require(project.id)
        let chat = try database.insert(Chat(projectId: projectID, title: "Refunds", body: "", source: .chat, status: .running, createdAt: now, updatedAt: now))
        let run = try database.insert(Run(projectId: projectID, taskId: try #require(chat.id), workflow: "w", status: .running, startedAt: now), state: RunEngineState())
        let agent = try database.insert(Agent(projectId: projectID, runId: run.id, role: "builder", name: "django-dev-1", status: .working, createdAt: now, updatedAt: now))
        let reporter = StallReporter(database: database)
        let silentSince = now.addingTimeInterval(-14 * 60)
        let stalled = StalledWorker(agent: agent, lastOutputAt: silentSince, stallMinutes: 10)

        let first = try reporter.report([stalled], now: now)
        let again = try reporter.report([stalled], now: now.addingTimeInterval(60))
        let tooSoon = try reporter.report([StalledWorker(agent: agent, lastOutputAt: now, stallMinutes: 10)], now: now.addingTimeInterval(120))

        #expect(first.count == 1)
        #expect(first.first?.kind == .failure)
        #expect(first.first?.taskId == chat.id)
        #expect(first.first?.body == "No output for 14 min. It may be waiting on a prompt or a hung command.")
        #expect(again.isEmpty)
        #expect(tooSoon.isEmpty)
    }
}
