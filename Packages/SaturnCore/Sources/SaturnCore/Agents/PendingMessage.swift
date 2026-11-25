import Foundation
import Observation

public struct PendingMessage: Sendable, Hashable {
    public var text: String
    public var attachments: [ChatAttachment]

    public init(text: String, attachments: [ChatAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    public func appending(_ held: PendingMessage) -> PendingMessage {
        guard !isEmpty else { return held }
        let draftText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let heldText = held.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let joinedText = [draftText, heldText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var merged = attachments
        for attachment in held.attachments {
            if case .pastedText(let id, _, let pasted) = attachment {
                merged.append(.pastedText(id: id, index: ChatAttachment.nextPasteIndex(after: merged), text: pasted))
            } else {
                merged.append(attachment)
            }
        }
        return PendingMessage(text: joinedText, attachments: merged)
    }
}

@MainActor
@Observable
public final class ReturnedMessages<Target: Hashable> {
    public private(set) var returned: [Target: PendingMessage] = [:]

    public init() {}

    public func returnToComposer(_ message: PendingMessage, for target: Target) {
        returned[target] = returned[target].map { $0.appending(message) } ?? message
    }

    public func takeReturned(for target: Target) -> PendingMessage? {
        returned.removeValue(forKey: target)
    }
}
