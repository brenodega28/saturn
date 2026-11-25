import Foundation

@MainActor
public final class SpecReviewSession {
    public let taskId: Int64
    public let file: URL
    public private(set) var url: URL?
    public var isListening: Bool { listener != nil }
    let lavish: LavishRuntime
    let deliver: @MainActor ([LavishPrompt]) async -> Void
    var retryDelay: Duration = .seconds(2)
    var maxFailures = 5
    private var listener: Task<Void, Never>?
    private var generation = 0

    public init(taskId: Int64, file: URL, lavish: LavishRuntime, deliver: @escaping @MainActor ([LavishPrompt]) async -> Void) {
        self.taskId = taskId
        self.file = file
        self.lavish = lavish
        self.deliver = deliver
    }

    @discardableResult
    public func open() async throws -> URL {
        let opened = try await lavish.open(file: file)
        url = opened
        return opened
    }

    public func listen(takeover: Bool = false) {
        guard listener == nil else { return }
        generation += 1
        let current = generation
        listener = Task { [weak self] in
            await self?.loop(takeover: takeover)
            self?.finished(current)
        }
    }

    public func stopListening() {
        listener?.cancel()
        listener = nil
    }

    public func end() async {
        stopListening()
        try? await lavish.end(file: file)
        url = nil
    }

    public func reply(_ text: String) async throws {
        try await lavish.reply(file: file, text: text)
    }

    private func finished(_ current: Int) {
        if generation == current { listener = nil }
    }

    private func loop(takeover initial: Bool) async {
        var takeover = initial
        var failures = 0
        while !Task.isCancelled {
            do {
                let result = try await lavish.poll(file: file, takeover: takeover)
                takeover = false
                failures = 0
                guard !Task.isCancelled else { return }
                switch result {
                case .feedback(let prompts, let sessionEnded):
                    await deliver(prompts)
                    if sessionEnded { return }
                case .ended, .browserDisconnected:
                    return
                case .waiting:
                    continue
                }
            } catch LavishError.listenerActive {
                takeover = true
            } catch LavishError.listenerReplaced, LavishError.noSession {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                if failures >= maxFailures { return }
                try? await Task.sleep(for: retryDelay)
            }
        }
    }
}

public struct SpecReviewStatus: Codable, Sendable, Hashable {
    public var url: String?
    public var reason: String?
    public var port: Int?

    public init(url: String? = nil, reason: String? = nil) {
        self.url = url
        self.reason = reason
        self.port = url.flatMap(URL.init(string:))?.port
    }

    public var lavishPort: Int? {
        port ?? url.flatMap(URL.init(string:))?.port
    }

    public func forwarded(to localPort: Int) -> SpecReviewStatus {
        guard let url, var components = URLComponents(string: url) else { return self }
        components.port = localPort
        var status = self
        status.url = components.url?.absoluteString ?? url
        return status
    }
}

@MainActor
public protocol SpecReviewHost: AnyObject {
    func specDrafted(projectId: Int64, taskId: Int64) async -> SpecReviewStatus
    func replySpec(taskId: Int64, text: String) async throws
    func endSpecReview(taskId: Int64) async
}

@MainActor
public final class SpecReviews: SpecReviewHost {
    public let paths: AppPaths
    public let database: AppDatabase
    public var makeRuntime: @MainActor () async throws -> LavishRuntime
    public var deliver: @MainActor (_ taskId: Int64, _ message: String) async -> Void = { _, _ in }
    public var approve: @MainActor (_ taskId: Int64) async throws -> Void = { _ in throw SpecReviewError.approvalUnavailable }
    public var drafted: @MainActor (_ projectId: Int64, _ taskId: Int64, _ path: String) -> Void = { _, _, _ in }
    public var ended: @MainActor (_ taskId: Int64) -> Void = { _ in }
    public private(set) var sessions: [Int64: SpecReviewSession] = [:]
    private var opening: [Int64: Task<URL, Error>] = [:]
    private var approving: Set<Int64> = []
    private var endAfterApproval: Set<Int64> = []

    public init(paths: AppPaths, database: AppDatabase, makeRuntime: @escaping @MainActor () async throws -> LavishRuntime) {
        self.paths = paths
        self.database = database
        self.makeRuntime = makeRuntime
    }

    var store: SpecStore { SpecStore(paths: paths, database: database) }
    var ledger: URL { paths.root.appending(path: "spec-reviews.json") }

    public func status(taskId: Int64) async -> SpecReviewStatus {
        do {
            return SpecReviewStatus(url: try await ensure(taskId: taskId).absoluteString)
        } catch {
            return SpecReviewStatus(reason: error.localizedDescription)
        }
    }

    @discardableResult
    public func ensure(taskId: Int64, takeover: Bool = false) async throws -> URL {
        let page = try reviewablePage(taskId: taskId)
        if let session = sessions[taskId], let url = session.url, session.isListening { return url }
        if let pending = opening[taskId] { return try await pending.value }
        let task = Task { @MainActor in
            let session = try await self.session(taskId: taskId, file: page)
            let url = try await session.open()
            session.listen(takeover: takeover)
            self.save()
            return url
        }
        opening[taskId] = task
        defer { opening[taskId] = nil }
        return try await task.value
    }

    public func specDrafted(projectId: Int64, taskId: Int64) async -> SpecReviewStatus {
        let page = store.pageURL(projectId: projectId, taskId: taskId)
        let review = await status(taskId: taskId)
        drafted(projectId, taskId, page.path)
        return review
    }

    public func replySpec(taskId: Int64, text: String) async throws {
        guard let session = sessions[taskId], session.url != nil else {
            throw HandoffError.notAllowed("No Lavish review is open for this request’s spec, so there’s nothing to reply on. Answer in the chat instead.")
        }
        try await session.reply(text)
    }

    public func endSpecReview(taskId: Int64) async {
        if approving.contains(taskId) {
            endAfterApproval.insert(taskId)
            return
        }
        guard let session = sessions.removeValue(forKey: taskId) else { return }
        save()
        await session.end()
        ended(taskId)
    }

    public func resume() async {
        for taskId in saved() {
            do {
                try await ensure(taskId: taskId, takeover: true)
            } catch {
                if let page = try? draftPage(taskId: taskId), let lavish = try? await makeRuntime() {
                    try? await lavish.end(file: page)
                }
                sessions[taskId] = nil
            }
        }
        save()
    }

    public func stopListening() {
        sessions.values.forEach { $0.stopListening() }
    }

    func session(taskId: Int64, file: URL) async throws -> SpecReviewSession {
        if let existing = sessions[taskId] { return existing }
        let lavish = try await makeRuntime()
        let session = SpecReviewSession(taskId: taskId, file: file, lavish: lavish) { [weak self] prompts in
            await self?.received(prompts, taskId: taskId)
        }
        sessions[taskId] = session
        return session
    }

    func received(_ prompts: [LavishPrompt], taskId: Int64) async {
        guard let chat = try? database.task(id: taskId) else { return }
        let (approvals, notes) = SpecFeedback.split(prompts)
        let document = try? store.draft(projectId: chat.projectId, taskId: taskId)
        if let message = SpecFeedback.message(for: notes, document: document) { await deliver(taskId, message) }
        if !approvals.isEmpty { await approveFromPage(taskId: taskId) }
    }

    func approveFromPage(taskId: Int64) async {
        approving.insert(taskId)
        let reply: String
        do {
            try await approve(taskId)
            reply = "Approved, run started."
        } catch {
            reply = "Not started: \(error.localizedDescription)"
        }
        try? await sessions[taskId]?.reply(reply)
        approving.remove(taskId)
        guard endAfterApproval.remove(taskId) != nil else { return }
        Task { await self.endSpecReview(taskId: taskId) }
    }

    func draftPage(taskId: Int64) throws -> URL {
        guard let chat = try database.task(id: taskId) else { throw CommandFailure.notFound("The chat") }
        guard let page = store.ensurePage(projectId: chat.projectId, taskId: taskId) else {
            throw SpecReviewError.noDraft
        }
        return page
    }

    func reviewablePage(taskId: Int64) throws -> URL {
        guard let chat = try database.task(id: taskId) else { throw CommandFailure.notFound("The chat") }
        if chat.isClosed { throw SpecReviewError.closed }
        if try database.project(id: chat.projectId)?.host != nil { throw SpecReviewError.remote }
        let page = try draftPage(taskId: taskId)
        let status = (try? store.draft(projectId: chat.projectId, taskId: taskId))??.status ?? .draft
        guard status == .draft || status == .rejected else { throw SpecReviewError.committed }
        return page
    }

    func saved() -> [Int64] {
        guard let data = try? Data(contentsOf: ledger) else { return [] }
        return (try? JSONDecoder().decode([Int64].self, from: data)) ?? []
    }

    func save() {
        let ids = sessions.keys.sorted()
        try? FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: ledger, options: .atomic)
    }
}

public enum SpecReviewError: Error, LocalizedError, Equatable {
    case noDraft
    case remote
    case committed
    case closed
    case approvalUnavailable

    public var errorDescription: String? {
        switch self {
        case .noDraft: "This request has no spec draft yet."
        case .remote: "Live review in Lavish isn’t available for remote projects, so the spec opens read-only. Send feedback in the chat."
        case .committed: "The run started and the spec is committed on the run branch, so the page is read-only."
        case .closed: "This request is closed, so the spec is read-only."
        case .approvalUnavailable: "Approving from the page isn’t set up in this Saturn. Approve the spec in the Saturn chat."
        }
    }
}
