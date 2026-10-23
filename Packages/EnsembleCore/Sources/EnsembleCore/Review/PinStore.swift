import Foundation
import GRDB

extension AppDatabase {
    public func pins(runId: Int64) throws -> [Pin] {
        try writer.read { db in try Self.pinsRequest(runId: runId).fetchAll(db) }
    }

    public func pin(id: Int64) throws -> Pin? {
        try writer.read { db in try Pin.fetchOne(db, id: id) }
    }

    @discardableResult
    public func createPin(_ draft: PinDraft, runId: Int64, agentId: Int64?, now: Date = .now) throws -> Pin {
        try writer.write { db in
            var pin = Pin(
                runId: runId, agentId: agentId, file: draft.file, startLine: min(draft.startLine, draft.endLine),
                endLine: max(draft.startLine, draft.endLine), title: draft.title, tags: draft.tags,
                explanation: draft.explanation, createdAt: now, updatedAt: now
            )
            try pin.insert(db)
            return pin
        }
    }

    @discardableResult
    public func updatePin(id: Int64, status: PinStatus, response: String? = nil, now: Date = .now) throws -> Pin? {
        try writer.write { db in
            guard var pin = try Pin.fetchOne(db, id: id) else { return nil }
            pin.status = status
            pin.response = response
            pin.updatedAt = now
            try pin.update(db)
            return pin
        }
    }

    @discardableResult
    public func approveOpenPins(runId: Int64, now: Date = .now) throws -> Int {
        try writer.write { db in
            try Pin
                .filter(Pin.Columns.runId == runId)
                .filter(Pin.Columns.status == PinStatus.open.rawValue)
                .updateAll(db, Pin.Columns.status.set(to: PinStatus.approved.rawValue), Column("updatedAt").set(to: now))
        }
    }

    public func openPinCount(runId: Int64) throws -> Int {
        try writer.read { db in
            try Pin.filter(Pin.Columns.runId == runId).filter(Pin.Columns.status == PinStatus.open.rawValue).fetchCount(db)
        }
    }

    public func openPinCounts(projectId: Int64) throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pin.runId AS runId, COUNT(*) AS total FROM pin
                JOIN run ON run.id = pin.runId
                WHERE run.projectId = ? AND pin.status = ?
                GROUP BY pin.runId
                """, arguments: [projectId, PinStatus.open.rawValue])
            return Dictionary(uniqueKeysWithValues: rows.map { (Int64($0["runId"] as Int64), Int($0["total"] as Int)) })
        }
    }

    public func pinUpdates(runId: Int64) -> AsyncThrowingStream<[Pin], any Error> {
        let observation = ValueObservation.tracking { db in try Self.pinsRequest(runId: runId).fetchAll(db) }
        let values = observation.values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await pins in values { continuation.yield(pins) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func pinsRequest(runId: Int64) -> QueryInterfaceRequest<Pin> {
        Pin.filter(Pin.Columns.runId == runId).order(Column("file"), Column("startLine"), Column("id"))
    }
}

extension Pin {
    public var lineLabel: String {
        startLine == endLine ? "\(startLine)" : "\(startLine)–\(endLine)"
    }

    public var lineRange: ClosedRange<Int> { min(startLine, endLine)...max(startLine, endLine) }

    public static func changeRequestSummary(_ pins: [Pin], agentNames: [Int64: String] = [:]) -> String {
        let requested = pins.filter { $0.status == .changeRequested }
        guard !requested.isEmpty else { return "" }
        let items = requested.map { pin in
            let author = pin.agentId.flatMap { agentNames[$0] }.map { " (pinned by \($0))" } ?? ""
            let note = pin.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let request = note.isEmpty ? "Please revisit this." : note
            return "- \(pin.file):\(pin.lineLabel) “\(pin.title)”\(author): \(request)"
        }
        return (["Changes requested on \(requested.count) pin\(requested.count == 1 ? "" : "s"):"] + items).joined(separator: "\n")
    }
}
