import Foundation

public struct ChatDraft: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var projectID: Int64
    public var number: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var text: String
    public var attachments: [ChatAttachment]

    public init(
        id: UUID = UUID(), projectID: Int64, number: Int, createdAt: Date = .now, updatedAt: Date? = nil,
        text: String = "", attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.number = number
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.text = text
        self.attachments = attachments
    }

    public var title: String { "New chat \(number)" }

    public var message: PendingMessage {
        PendingMessage(text: text, attachments: attachments)
    }

    public var preview: String {
        let typed = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        return attachments.first?.label ?? ""
    }

    public static func lowestUnusedNumber(among drafts: [ChatDraft]) -> Int {
        let used = Set(drafts.map(\.number))
        return (1...).first { !used.contains($0) } ?? 1
    }
}
