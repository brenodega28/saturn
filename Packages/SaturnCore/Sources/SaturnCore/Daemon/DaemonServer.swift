import Foundation
import GRDB
import Synchronization

@MainActor
public final class DaemonServer {
    public let socketPath: URL
    private weak var host: SaturnHost?
    private var listener: SocketListener?
    private var sessions: [UUID: ClientSession] = [:]
    private var changeListener: UUID?

    init(host: SaturnHost, socket: URL) throws {
        self.host = host
        self.socketPath = socket
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        let changeLog = host.changeLog
        changeListener = changeLog.addListener { [weak self] _ in
            Task { @MainActor in self?.pumpAll() }
        }
        listener = try SocketListener(path: socket.path) { [weak self] descriptor in
            Task { @MainActor in self?.accept(LineChannel(socket: descriptor)) }
        }
    }

    public var clientCount: Int { sessions.values.filter(\.isStreaming).count }

    public func accept(_ channel: LineChannel) {
        guard let host else {
            channel.close()
            return
        }
        let session = ClientSession(host: host, channel: channel)
        sessions[session.id] = session
        channel.whenClosed { [weak self] in
            Task { @MainActor in self?.sessions[session.id] = nil }
        }
        session.start()
    }

    func broadcast(_ message: ProtocolMessage) {
        for session in sessions.values where session.isStreaming {
            session.send(message)
        }
    }

    private func pumpAll() {
        for session in sessions.values where session.isStreaming {
            session.pump()
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        if let changeListener { host?.changeLog.removeListener(changeListener) }
        for session in sessions.values {
            session.close()
        }
        sessions = [:]
    }
}

@MainActor
final class ClientSession {
    let id = UUID()
    let channel: LineChannel
    private weak var host: SaturnHost?
    private let identity: DaemonIdentity
    private let database: AppDatabase
    private let pumpState: PumpState
    private var files: [UUID: Task<Void, Never>] = [:]
    private(set) var isStreaming = false
    private(set) var isHandshaken = false
    private(set) var clientID: UUID?

    init(host: SaturnHost, channel: LineChannel) {
        self.host = host
        self.identity = host.identity
        self.database = host.database
        self.channel = channel
        self.pumpState = PumpState(changeLog: host.changeLog, channel: channel)
    }

    func start() {
        Task { @MainActor [weak self, channel] in
            for await line in channel.lines {
                guard let self else { return }
                let message: ProtocolMessage
                do {
                    message = try ProtocolMessage.decode(line)
                } catch {
                    self.send(.refused(Refusal(code: .badRequest, message: "The daemon couldn’t read a message: \(error.localizedDescription)", daemonProtocolVersion: SaturnProtocol.version)))
                    continue
                }
                self.receive(message)
            }
            self?.closeFiles()
        }
    }

    func send(_ message: ProtocolMessage) {
        do {
            try channel.send(message)
        } catch {
            channel.close()
        }
    }

    func close() {
        closeFiles()
        channel.close()
    }

    private func closeFiles() {
        files.values.forEach { $0.cancel() }
        files = [:]
    }

    func pump() {
        pumpState.pump()
    }

    private func receive(_ message: ProtocolMessage) {
        switch message {
        case .hello(let hello):
            handshake(hello)
        case .command(let envelope):
            guard isHandshaken else { return }
            Task { @MainActor [weak self] in
                guard let self, let host = self.host else { return }
                let result = await host.handle(envelope)
                await self.pumpState.flushThenSend(.result(result))
            }
        case .file(let request):
            guard isHandshaken else { return }
            files[request.requestID]?.cancel()
            files[request.requestID] = stream(request)
        case .fileCancel(let request):
            files.removeValue(forKey: request.requestID)?.cancel()
        case .bye:
            close()
        default:
            break
        }
    }

    private func handshake(_ hello: Hello) {
        guard !isHandshaken else { return }
        if hello.protocolVersion < SaturnProtocol.version {
            send(.refused(Refusal(
                code: .clientTooOld,
                message: "\(identity.name) runs a newer Saturn daemon (protocol \(SaturnProtocol.version)) than this Mac’s app (protocol \(hello.protocolVersion)). Update Saturn on this Mac to connect.",
                daemonProtocolVersion: SaturnProtocol.version
            )))
            channel.close()
            return
        }
        if hello.protocolVersion > SaturnProtocol.version {
            send(.refused(Refusal(
                code: .daemonTooOld,
                message: "The Saturn daemon on \(identity.name) is older (protocol \(SaturnProtocol.version)) than this app (protocol \(hello.protocolVersion)). Upgrade the daemon to connect.",
                daemonProtocolVersion: SaturnProtocol.version
            )))
            channel.close()
            return
        }
        clientID = hello.clientID
        send(.welcome(Welcome(daemon: identity, protocolVersion: SaturnProtocol.version, buildVersion: SaturnProtocol.buildVersion)))
        let replicaMatchesSchema = hello.replicaSchema.map { $0 == AppDatabase.latestMigration } ?? true
        let resume = hello.daemonID == identity.id && replicaMatchesSchema ? hello.lastSeq : nil
        isHandshaken = true
        pumpState.begin(resumeFrom: resume, hadSeq: hello.lastSeq != nil, database: database) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.send(.live(self.host?.live ?? LiveState()))
                self.isStreaming = true
                self.pump()
            }
        }
    }

    private func stream(_ request: FileRequest) -> Task<Void, Never> {
        let url = host?.fileURL(for: request)
        let channel = channel
        return Task.detached {
            func chunk(offset: Int64, data: Data = Data(), end: Bool, error: String? = nil, caughtUp: Bool = false) -> Bool {
                let message = FileChunk(requestID: request.requestID, offset: offset, data: data, end: end, error: error, caughtUp: caughtUp)
                return (try? channel.send(.fileChunk(message))) != nil
            }
            guard let url else {
                _ = chunk(offset: request.offset, end: true, error: "Unknown file")
                return
            }
            var offset = request.offset
            var announcedCatchUp = false
            while !Task.isCancelled {
                if let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()).map { Int64($0) } ?? 0
                    if size < offset { offset = 0 }
                    try? handle.seek(toOffset: UInt64(offset))
                    while !Task.isCancelled, let data = try? handle.read(upToCount: 256 * 1024), !data.isEmpty {
                        guard chunk(offset: offset, data: data, end: false) else { return }
                        offset += Int64(data.count)
                    }
                } else if !request.follow {
                    _ = chunk(offset: offset, end: true, error: "The file doesn’t exist.")
                    return
                }
                guard request.follow else {
                    _ = chunk(offset: offset, end: true)
                    return
                }
                if !announcedCatchUp {
                    announcedCatchUp = true
                    guard chunk(offset: offset, end: false, caughtUp: true) else { return }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

final class PumpState: Sendable {
    private let changeLog: ChangeLog
    private let channel: LineChannel
    private let queue = DispatchQueue(label: "saturn.client-pump")
    private let sentSeq = Mutex<Int64?>(nil)

    init(changeLog: ChangeLog, channel: LineChannel) {
        self.changeLog = changeLog
        self.channel = channel
    }

    func begin(resumeFrom seq: Int64?, hadSeq: Bool, database: AppDatabase, ready: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            do {
                if let seq, try changeLog.canResume(from: seq) {
                    sentSeq.withLock { $0 = seq }
                } else {
                    if hadSeq {
                        try channel.send(.resync(ResyncNotice(oldestSeq: (try changeLog.oldestSeq()) ?? 0)))
                    }
                    try sendSnapshot(database: database)
                }
                drain()
                ready()
            } catch {
                channel.close()
            }
        }
    }

    private func sendSnapshot(database: AppDatabase) throws {
        changeLog.waitUntilFlushed()
        let seq = try changeLog.latestSeq()
        let file = FileManager.default.temporaryDirectory.appending(path: "saturnd-snapshot-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        let destination = try DatabaseQueue(path: file.path)
        try database.writer.backup(to: destination)
        try destination.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM changeLog")
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try destination.close()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        try channel.send(.snapshotBegin(SnapshotHeader(seq: seq, size: size)))
        while let data = try handle.read(upToCount: 512 * 1024), !data.isEmpty {
            try channel.send(.snapshotChunk(SnapshotChunk(data: data)))
        }
        try channel.send(.snapshotEnd(SnapshotHeader(seq: seq, size: size)))
        sentSeq.withLock { $0 = seq }
    }

    func pump() {
        queue.async { [self] in drain() }
    }

    func flushThenSend(_ message: ProtocolMessage) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                changeLog.waitUntilFlushed()
                drain()
                try? channel.send(message)
                continuation.resume()
            }
        }
    }

    private func drain() {
        guard var seq = sentSeq.withLock({ $0 }) else { return }
        do {
            while true {
                let changes = try changeLog.changes(after: seq, limit: 500)
                guard let last = changes.last else { return }
                try channel.send(.changes(ChangeBatch(changes: changes, seq: last.seq)))
                seq = last.seq
                sentSeq.withLock { $0 = seq }
            }
        } catch {
            channel.close()
        }
    }
}

extension SaturnHost {
    func fileURL(for request: FileRequest) -> URL? {
        switch request.kind {
        case .transcript:
            return Int64(request.id).map(paths.transcript)
        case .agentFile:
            let parts = request.id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let agentID = Int64(parts[0]), !parts[1].contains("..") else { return nil }
            return paths.agentDirectory(agentID).appending(path: parts[1])
        case .attachment:
            guard !request.id.contains("/"), !request.id.contains("..") else { return nil }
            return paths.attachmentsDirectory.appending(path: request.id)
        case .specDraft:
            let parts = request.id.split(separator: "/").compactMap { Int64($0) }
            guard parts.count == 2 else { return nil }
            return paths.specDraft(projectId: parts[0], taskId: parts[1])
        case .evidence:
            guard let id = Int64(request.id), let evidence = try? database.writer.read({ db in try Evidence.fetchOne(db, id: id) }) else { return nil }
            if evidence.file.hasPrefix("/") { return URL(fileURLWithPath: evidence.file) }
            return paths.evidenceDirectory(runId: evidence.runId).appending(path: evidence.file)
        }
    }
}
