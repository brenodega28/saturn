import Foundation
import GRDB

public struct Correction: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "correction"

    public var id: Int64?
    public var projectId: Int64
    public var runId: Int64?
    public var pinId: Int64?
    public var file: String?
    public var text: String
    public var createdAt: Date
    public var encodedAt: Date?
    public var encoding: String?

    public init(
        id: Int64? = nil, projectId: Int64, runId: Int64?, pinId: Int64?, file: String?, text: String, createdAt: Date,
        encodedAt: Date? = nil, encoding: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.runId = runId
        self.pinId = pinId
        self.file = file
        self.text = text
        self.createdAt = createdAt
        self.encodedAt = encodedAt
        self.encoding = encoding
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isEncoded: Bool { encodedAt != nil }

    static let stopWords: Set<String> = [
        "the", "and", "for", "this", "that", "with", "you", "your", "are", "not", "but", "use", "should", "please", "here",
        "there", "from", "into", "when", "then", "than", "them", "they", "its", "it's", "was", "were", "have", "has", "can",
        "don't", "dont", "instead", "also", "just", "like", "make", "sure", "need", "needs", "again", "all", "any",
    ]

    public var keywords: Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "'" }
            .map(String.init)
            .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
            .map { $0.hasSuffix("s") && $0.count > 4 ? String($0.dropLast()) : $0 })
    }

    public func resembles(_ other: Correction, threshold: Double = 0.5) -> Bool {
        let mine = keywords, theirs = other.keywords
        guard !mine.isEmpty, !theirs.isEmpty else { return false }
        return Double(mine.intersection(theirs).count) / Double(mine.union(theirs).count) >= threshold
    }
}

extension AppDatabase {
    public func corrections(projectId: Int64) throws -> [Correction] {
        try writer.read { db in
            try Correction.filter(Column("projectId") == projectId).order(Column("createdAt").desc, Column("id").desc).fetchAll(db)
        }
    }

    @discardableResult
    public func recordCorrection(runId: Int64, pinId: Int64?, file: String?, text: String, now: Date = .now) throws -> Correction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let correction = try writer.write { db -> Correction? in
            guard let run = try Run.fetchOne(db, id: runId) else { return nil }
            if let pinId, var existing = try Correction.filter(Column("pinId") == pinId).fetchOne(db) {
                existing.text = trimmed
                try existing.update(db)
                return nil
            }
            var correction = Correction(projectId: run.projectId, runId: runId, pinId: pinId, file: file, text: trimmed, createdAt: now)
            try correction.insert(db)
            return correction
        }
        guard let correction else { return nil }
        if let earlier = try repeatOf(correction) {
            try createInboxItem(InboxItem(
                projectId: correction.projectId, runId: correction.runId, kind: .notice,
                title: "You’ve asked for this before",
                body: "“\(correction.text)”\n\nLooks like your earlier correction “\(earlier.text)”. Encode it as a rule, a check or a protected path in Settings › Learned Rules so agents stop repeating the mistake.",
                createdAt: now
            ))
        }
        return correction
    }

    public func repeatOf(_ correction: Correction) throws -> Correction? {
        try corrections(projectId: correction.projectId).first { earlier in
            earlier.id != correction.id && earlier.runId != correction.runId && !earlier.isEncoded && correction.resembles(earlier)
        }
    }

    public func repeatedCorrections(projectId: Int64) throws -> Set<Int64> {
        let all = try corrections(projectId: projectId).filter { !$0.isEncoded }
        var repeated: Set<Int64> = []
        for (index, correction) in all.enumerated() {
            for other in all[(index + 1)...] where other.runId != correction.runId && correction.resembles(other) {
                if let id = correction.id { repeated.insert(id) }
                if let id = other.id { repeated.insert(id) }
            }
        }
        return repeated
    }

    public func markEncoded(_ correction: Correction, encoding: String, now: Date = .now) throws {
        let similar = try corrections(projectId: correction.projectId).filter { !$0.isEncoded && ($0.id == correction.id || $0.resembles(correction)) }
        try writer.write { db in
            for var item in similar {
                item.encodedAt = now
                item.encoding = encoding
                try item.update(db)
            }
        }
    }
}
