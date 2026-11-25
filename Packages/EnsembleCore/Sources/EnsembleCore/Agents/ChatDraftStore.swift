import Foundation
import Observation

@MainActor
@Observable
public final class ChatDraftStore {
    private struct StoredMessage: Codable {
        var text: String
        var attachments: [ChatAttachment]
    }

    private enum Key: Hashable {
        case newDraft(UUID)
        case chat(Int64)
    }

    public let directory: URL
    private var drafts: [UUID: ChatDraft] = [:]
    private var chatDrafts: [Int64: PendingMessage] = [:]
    @ObservationIgnored private var unsaved: Set<Key> = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private let saveDelay: Duration

    public init(directory: URL, saveDelay: Duration = .milliseconds(400)) {
        self.directory = directory
        self.saveDelay = saveDelay
        load()
    }

    public func newDrafts() -> [ChatDraft] {
        drafts.values.sorted { ($0.number, $0.createdAt) < ($1.number, $1.createdAt) }
    }

    public func newDraft(id: UUID) -> ChatDraft? {
        drafts[id]
    }

    @discardableResult
    public func createNewDraft(projectID: Int64) -> ChatDraft {
        let draft = ChatDraft(projectID: projectID, number: ChatDraft.lowestUnusedNumber(among: Array(drafts.values)))
        drafts[draft.id] = draft
        write(.newDraft(draft.id))
        return draft
    }

    public func save(_ draft: ChatDraft) {
        guard drafts[draft.id] != draft else { return }
        drafts[draft.id] = draft
        markUnsaved(.newDraft(draft.id))
    }

    public func updateNewDraft(id: UUID, with message: PendingMessage) {
        guard var draft = drafts[id], draft.message != message else { return }
        draft.text = message.text
        draft.attachments = message.attachments
        draft.updatedAt = .now
        save(draft)
    }

    public func deleteNewDraft(id: UUID) {
        drafts[id] = nil
        unsaved.remove(.newDraft(id))
        try? FileManager.default.removeItem(at: url(for: .newDraft(id)))
    }

    public func chatDraft(chatID: Int64) -> PendingMessage? {
        chatDrafts[chatID]
    }

    public func setChatDraft(_ message: PendingMessage, chatID: Int64) {
        guard !message.text.isEmpty || !message.attachments.isEmpty else {
            clearChatDraft(chatID: chatID)
            return
        }
        guard chatDrafts[chatID] != message else { return }
        chatDrafts[chatID] = message
        markUnsaved(.chat(chatID))
    }

    public func clearChatDraft(chatID: Int64) {
        guard chatDrafts.removeValue(forKey: chatID) != nil || unsaved.contains(.chat(chatID)) else { return }
        markUnsaved(.chat(chatID))
    }

    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let keys = unsaved
        unsaved = []
        keys.forEach(write)
    }

    private func markUnsaved(_ key: Key) {
        unsaved.insert(key)
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.pendingSave = nil
            self?.flush()
        }
    }

    private func write(_ key: Key) {
        let url = url(for: key)
        let data: Data?
        switch key {
        case .newDraft(let id): data = drafts[id].flatMap { try? Self.encoder.encode($0) }
        case .chat(let chatID): data = chatDrafts[chatID].flatMap { try? Self.encoder.encode(StoredMessage(text: $0.text, attachments: $0.attachments)) }
        }
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        for url in files(in: newDraftsDirectory) {
            if let draft = try? Self.decoder.decode(ChatDraft.self, from: Data(contentsOf: url)) { drafts[draft.id] = draft }
        }
        for url in files(in: chatDraftsDirectory) {
            guard let chatID = Int64(url.deletingPathExtension().lastPathComponent),
                  let stored = try? Self.decoder.decode(StoredMessage.self, from: Data(contentsOf: url)) else { continue }
            chatDrafts[chatID] = PendingMessage(text: stored.text, attachments: stored.attachments)
        }
    }

    private func files(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "json" }
    }

    private var newDraftsDirectory: URL { directory.appending(path: "new", directoryHint: .isDirectory) }

    private var chatDraftsDirectory: URL { directory.appending(path: "chats", directoryHint: .isDirectory) }

    private func url(for key: Key) -> URL {
        switch key {
        case .newDraft(let id): newDraftsDirectory.appending(path: "\(id.uuidString.lowercased()).json")
        case .chat(let chatID): chatDraftsDirectory.appending(path: "\(chatID).json")
        }
    }

    func newDraftURL(id: UUID) -> URL { url(for: .newDraft(id)) }

    func chatDraftURL(chatID: Int64) -> URL { url(for: .chat(chatID)) }

    private static let encoder = JSONEncoder()

    private static let decoder = JSONDecoder()
}
