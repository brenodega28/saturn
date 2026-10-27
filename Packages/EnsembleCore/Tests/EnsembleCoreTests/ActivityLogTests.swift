import Foundation
import Testing
@testable import EnsembleCore

@MainActor
struct ActivityLogTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func runProgressBecomesLogLines() {
        let start = ActivitySnapshot()
        let running = ActivitySnapshot(runs: [7: .init(projectId: 1, title: "Refunds v2", status: .running, step: "Build")])
        let holding = ActivitySnapshot(runs: [7: .init(projectId: 1, title: "Refunds v2", status: .waitingOnYou, step: "Checks", hold: "Checks still failed after 2 rounds.\n\ndetails")])
        let failed = ActivitySnapshot(runs: [7: .init(projectId: 1, title: "Refunds v2", status: .failed, step: "Checks", hold: "Checks still failed after 2 rounds.\n\ndetails", error: "pytest exited 1")])

        let first = ActivityDiff.events(from: start, to: running, at: now)
        let second = ActivityDiff.events(from: running, to: holding, at: now)
        let third = ActivityDiff.events(from: holding, to: failed, at: now)

        #expect(first.map(\.message) == ["Refunds v2: run started", "Refunds v2: Build started"])
        #expect(first.map(\.level) == [.info, .info])
        #expect(second.map(\.message) == ["Refunds v2: Checks started", "Refunds v2: waiting on you · Checks still failed after 2 rounds."])
        #expect(second.last?.level == .warning)
        #expect(third.map(\.message) == ["Refunds v2: run failed · pytest exited 1"])
        #expect(third.first?.level == .error)
        #expect(third.first?.runId == 7)
    }

    @Test func agentToolsAndStatusChangesAreLogged() {
        let edit = ActivitySnapshot.ToolState(id: "t1", name: "Edit", target: "backend/orders/serializers.py")
        let failing = ActivitySnapshot.ToolState(id: "t2", name: "Bash", target: "pytest -q\nmore", isError: true)
        let before = ActivitySnapshot(agents: [3: .init(projectId: 1, name: "django-1", status: .working, runId: 7, step: "Build")])
        let after = ActivitySnapshot(agents: [3: .init(projectId: 1, name: "django-1", status: .needsInput, runId: 7, step: "Build", finishedTools: [edit, failing])])

        let events = ActivityDiff.events(from: before, to: after, at: now)

        #expect(events.map(\.message) == ["edit backend/orders/serializers.py", "bash pytest -q failed", "needs you"])
        #expect(events.map(\.level) == [.debug, .warning, .warning])
        #expect(events.allSatisfy { $0.source == "django-1" && $0.agentId == 3 && $0.step == "Build" })
    }

    @Test func aNewlySeenAgentDoesntReplayItsHistory() {
        let after = ActivitySnapshot(agents: [3: .init(projectId: 1, name: "django-1", status: .idle, finishedTools: [.init(id: "t1", name: "Read", target: "README.md")])])

        #expect(ActivityDiff.events(from: ActivitySnapshot(), to: after, at: now).isEmpty)
    }

    @Test func theLogKeepsTheNewestEntriesAndFilters() {
        let log = ActivityLog(capacity: 3)
        log.append([
            LogEntry(date: now, level: .debug, source: "dj1", agentId: 1, step: "Build", message: "edit serializers.py"),
            LogEntry(date: now, level: .info, source: "checks", step: "Checks", message: "format passed"),
            LogEntry(date: now, level: .warning, source: "dj2", agentId: 2, step: "Build", message: "waiting on you: squash migrations?"),
            LogEntry(date: now, level: .error, source: "checks", projectId: 2, step: "Checks", message: "IntegrityError on orders_refund_idempotency_key"),
        ])

        #expect(log.entries.map(\.id) == [2, 3, 4])
        #expect(log.entries(matching: LogFilter(step: "Checks")).map(\.id) == [2, 4])
        #expect(log.entries(matching: LogFilter(levels: [.warning, .error])).map(\.id) == [3, 4])
        #expect(log.entries(matching: LogFilter(agentId: 2)).map(\.id) == [3])
        #expect(log.entries(matching: LogFilter(text: "squash")).map(\.id) == [3])
        #expect(log.entries(matching: LogFilter(text: "/idempotency_\\w+")).map(\.id) == [4])
        #expect(log.entries(matching: LogFilter(), projectIds: [1]).map(\.id) == [2, 3])
    }
}
