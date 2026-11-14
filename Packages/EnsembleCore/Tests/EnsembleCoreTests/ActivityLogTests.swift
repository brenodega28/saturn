import Foundation
import Testing
@testable import EnsembleCore

@MainActor
struct ActivityLogTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

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
