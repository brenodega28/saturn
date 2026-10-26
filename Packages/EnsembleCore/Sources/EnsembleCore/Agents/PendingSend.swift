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
public protocol PendingSendClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws
}

public struct SystemPendingSendClock: PendingSendClock {
    public init() {}

    public var now: Date { .now }

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        try await Task.sleep(for: .seconds(interval))
    }
}

@MainActor
@Observable
public final class PendingSends<Target: Hashable> {
    public struct Hold: Identifiable, Hashable {
        public let id: UUID
        public let target: Target
        public let message: PendingMessage
        public let scheduledAt: Date
        public let deadline: Date
    }

    public private(set) var holds: [Hold] = []
    public private(set) var returned: [Target: PendingMessage] = [:]
    @ObservationIgnored private let clock: any PendingSendClock
    @ObservationIgnored private var deliveries: [UUID: @MainActor (PendingMessage) -> Void] = [:]
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    public init(clock: any PendingSendClock = SystemPendingSendClock()) {
        self.clock = clock
    }

    public var now: Date { clock.now }

    public func holds(for target: Target) -> [Hold] {
        holds.filter { $0.target == target }
    }

    @discardableResult
    public func schedule(_ message: PendingMessage, for target: Target, delay: TimeInterval, deliver: @escaping @MainActor (PendingMessage) -> Void) -> Hold? {
        let queued = holds(for: target)
        guard delay > 0 || !queued.isEmpty else {
            deliver(message)
            return nil
        }
        let scheduledAt = clock.now
        let deadline = max(scheduledAt.addingTimeInterval(max(delay, 0)), queued.last?.deadline ?? .distantPast)
        let hold = Hold(id: UUID(), target: target, message: message, scheduledAt: scheduledAt, deadline: deadline)
        holds.append(hold)
        deliveries[hold.id] = deliver
        let clock = clock
        timers[hold.id] = Task { @MainActor [weak self] in
            try? await clock.sleep(until: deadline)
            self?.fireDue(for: target)
        }
        return hold
    }

    @discardableResult
    public func undo(_ id: UUID) -> PendingMessage? {
        guard let index = holds.firstIndex(where: { $0.id == id }) else { return nil }
        let hold = holds.remove(at: index)
        deliveries[id] = nil
        timers.removeValue(forKey: id)?.cancel()
        return hold.message
    }

    @discardableResult
    public func undoLatest(for target: Target) -> PendingMessage? {
        holds(for: target).last.flatMap { undo($0.id) }
    }

    public func returnToComposer(_ message: PendingMessage, for target: Target) {
        returned[target] = returned[target].map { $0.appending(message) } ?? message
    }

    public func takeReturned(for target: Target) -> PendingMessage? {
        returned.removeValue(forKey: target)
    }

    public func fireDue(for target: Target) {
        let now = clock.now
        while let hold = holds.first(where: { $0.target == target }), hold.deadline <= now {
            holds.removeAll { $0.id == hold.id }
            timers.removeValue(forKey: hold.id)
            deliveries.removeValue(forKey: hold.id)?(hold.message)
        }
    }
}
