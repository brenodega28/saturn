import Foundation

public enum ProjectRecency {
    public static func lastUsed(_ project: Project, chats: [Chat], activity: [Int64: Date]) -> Date {
        chats.reduce(project.lastOpenedAt) { latest, chat in
            let touched = chat.id.flatMap { activity[$0] } ?? chat.updatedAt
            return max(latest, touched, chat.createdAt)
        }
    }

    public static func sorted<Item>(_ items: [Item], name: (Item) -> String, lastUsed: (Item) -> Date) -> [Item] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, name: name($0.element), date: lastUsed($0.element)) }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.offset < rhs.offset
            }
            .map(\.item)
    }
}
