import Foundation
import Observation

public enum DaemonTransport: Sendable {
    case socket(URL)
    case process(executable: URL, arguments: [String])
    case custom(@Sendable () throws -> LineChannel)

    func open() throws -> (LineChannel, Process?) {
        switch self {
        case .socket(let url):
            return (LineChannel(socket: try UnixSocket.connect(path: url.path)), nil)
        case .process(let executable, let arguments):
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let channel = LineChannel(
                readDescriptor: output.fileHandleForReading.fileDescriptor,
                writeDescriptor: input.fileHandleForWriting.fileDescriptor,
                ownsDescriptors: false
            )
            let reader = output.fileHandleForReading
            let writer = input.fileHandleForWriting
            channel.whenClosed { [process] in
                if process.isRunning { process.terminate() }
                try? writer.close()
                _ = reader
            }
            return (channel, process)
        case .custom(let make):
            return (try make(), nil)
        }
    }
}

public enum FileStreamEvent: Sendable {
    case data(Data)
    case caughtUp
}

public enum DaemonConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case syncing
    case connected
    case disconnected(String)
    case refused(String, RefusalCode)

    public var isConnected: Bool { self == .connected }
}

@MainActor
@Observable
public final class DaemonClient {
    public let clientID: UUID
    public let transport: DaemonTransport
    public let replicasDirectory: URL
    public private(set) var state: DaemonConnectionState = .idle
    public private(set) var identity: DaemonIdentity?
    public private(set) var buildVersion: String?
    public private(set) var replica: ReplicaDatabase?
    public private(set) var live = LiveState()
    public private(set) var snapshotsReceived = 0
    public private(set) var resyncsReceived = 0
    public private(set) var lastError: String?
    @ObservationIgnored public var onEvent: (@MainActor (DaemonEvent) -> Void)?
    @ObservationIgnored public var onReplicaReady: (@MainActor (ReplicaDatabase) -> Void)?
    @ObservationIgnored public var commandConnectTimeout: Duration = .seconds(15)
    @ObservationIgnored public var backoff:[Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    @ObservationIgnored private var channel: LineChannel?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<ResultEnvelope, Error>] = [:]
    @ObservationIgnored private var files: [UUID: AsyncThrowingStream<FileStreamEvent, Error>.Continuation] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var connectedWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isRunning = false

    public init(clientID: UUID = UUID(), transport: DaemonTransport, replicasDirectory: URL, knownDaemon: DaemonIdentity? = nil) {
        self.clientID = clientID
        self.transport = transport
        self.replicasDirectory = replicasDirectory
        self.identity = knownDaemon
        if let knownDaemon {
            replica = try? openReplica(for: knownDaemon.id)
        }
    }

    public var database: AppDatabase? { replica?.database }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        isRunning = false
        loop?.cancel()
        loop = nil
        try? channel?.send(.bye)
        channel?.close()
        channel = nil
        process = nil
        failPending()
        state = .idle
    }

    public func disconnect() {
        channel?.close()
    }

    public func waitUntilConnected(timeout: Duration = .seconds(10)) async throws {
        if state == .connected { return }
        let deadline = ContinuousClock.now + timeout
        while state != .connected {
            if case .refused(let message, _) = state { throw CommandFailure(code: .failed, message: message) }
            guard ContinuousClock.now < deadline else {
                throw ChannelError.system("Timed out connecting to the Ensemble daemon\(lastError.map { ": \($0)" } ?? ".")")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public func send<C: DaemonCommand>(_ command: C) async throws -> C.Response {
        let envelope = try CommandCoding.envelope(command)
        if state != .connected, isRunning {
            try? await waitUntilConnected(timeout: commandConnectTimeout)
        }
        guard let channel, state == .connected else {
            throw ChannelError.system("Not connected to the Ensemble daemon\(identity.map { " on \($0.name)" } ?? "").")
        }
        let result: ResultEnvelope = try await withCheckedThrowingContinuation { continuation in
            pending[envelope.id] = continuation
            do {
                try channel.send(.command(envelope))
            } catch {
                pending[envelope.id] = nil
                continuation.resume(throwing: error)
            }
        }
        return try CommandCoding.response(of: C.self, from: result)
    }

    public func file(_ kind: FileKind, id: String, offset: Int64 = 0, follow: Bool = false) -> AsyncThrowingStream<Data, Error> {
        let events = fileEvents(kind, id: id, offset: offset, follow: follow)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .data(let data) = event { continuation.yield(data) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fileEvents(_ kind: FileKind, id: String, offset: Int64 = 0, follow: Bool = false) -> AsyncThrowingStream<FileStreamEvent, Error> {
        let request = FileRequest(kind: kind, id: id, offset: offset, follow: follow)
        return AsyncThrowingStream { continuation in
            guard let channel else {
                continuation.finish(throwing: ChannelError.closed)
                return
            }
            files[request.requestID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.files.removeValue(forKey: request.requestID) != nil else { return }
                    try? self.channel?.send(.fileCancel(request))
                }
            }
            do {
                try channel.send(.file(request))
            } catch {
                files[request.requestID] = nil
                continuation.finish(throwing: error)
            }
        }
    }

    public func readFile(_ kind: FileKind, id: String) async throws -> Data {
        var data = Data()
        for try await chunk in file(kind, id: id) { data.append(chunk) }
        return data
    }

    private func run() async {
        var attempt = 0
        while isRunning, !Task.isCancelled {
            state = .connecting
            do {
                let (channel, process) = try transport.open()
                self.channel = channel
                self.process = process
                try channel.send(.hello(Hello(clientID: clientID, daemonID: identity?.id, lastSeq: replica?.seq)))
                state = .syncing
                attempt = 0
                await receive(from: channel)
                guard self.channel === channel else { return }
                self.channel = nil
                self.process = nil
            } catch {
                lastError = error.localizedDescription
            }
            failPending()
            guard isRunning, !Task.isCancelled else { break }
            if case .refused = state {} else { state = .disconnected(lastError ?? "The daemon connection closed.") }
            let delay = backoff[min(attempt, backoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func failPending() {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: ChannelError.closed) }
        let streams = files
        files = [:]
        streams.values.forEach { $0.finish(throwing: ChannelError.closed) }
    }

    private func receive(from channel: LineChannel) async {
        let inbox = SnapshotInbox(directory: replicasDirectory)
        for await line in channel.lines {
            guard let message = try? ProtocolMessage.decode(line) else { continue }
            do {
                try await handle(message, inbox: inbox, channel: channel)
            } catch {
                lastError = error.localizedDescription
                channel.close()
            }
        }
        inbox.discard()
    }

    private func handle(_ message: ProtocolMessage, inbox: SnapshotInbox, channel: LineChannel) async throws {
        switch message {
        case .welcome(let welcome):
            if identity?.id != welcome.daemon.id {
                try replica?.close()
                replica = nil
            }
            identity = welcome.daemon
            buildVersion = welcome.buildVersion
            if replica == nil {
                replica = try openReplica(for: welcome.daemon.id)
            }
        case .refused(let refusal):
            lastError = refusal.message
            state = .refused(refusal.message, refusal.code)
            channel.close()
        case .resync:
            resyncsReceived += 1
        case .snapshotBegin:
            try inbox.begin()
        case .snapshotChunk(let chunk):
            try inbox.append(chunk.data)
        case .snapshotEnd(let header):
            guard let replica, let file = try inbox.finish() else { return }
            try await Self.offMain { try replica.applySnapshot(file: file, seq: header.seq) }
            inbox.discard()
            snapshotsReceived += 1
            becameConnected(replica)
        case .changes(let batch):
            guard let replica else { return }
            try await Self.offMain { try replica.apply(batch.changes, seq: batch.seq) }
        case .live(let state):
            live = state
            if self.state == .syncing, let replica, replica.seq != nil, !inbox.isReceiving {
                becameConnected(replica)
            }
        case .event(let event):
            onEvent?(event)
        case .result(let result):
            pending.removeValue(forKey: result.id)?.resume(returning: result)
        case .fileChunk(let chunk):
            guard let continuation = files[chunk.requestID] else { return }
            if !chunk.data.isEmpty { continuation.yield(.data(chunk.data)) }
            if chunk.caughtUp { continuation.yield(.caughtUp) }
            if chunk.end {
                files[chunk.requestID] = nil
                if let error = chunk.error {
                    continuation.finish(throwing: CommandFailure(code: .notFound, message: error))
                } else {
                    continuation.finish()
                }
            }
        default:
            break
        }
    }

    private func becameConnected(_ replica: ReplicaDatabase) {
        guard state != .connected else { return }
        state = .connected
        onReplicaReady?(replica)
    }

    private func openReplica(for id: DaemonID) throws -> ReplicaDatabase {
        let name = id.uuidString.lowercased()
        return try ReplicaDatabase(
            url: replicasDirectory.appending(path: "\(name).sqlite"),
            stateURL: replicasDirectory.appending(path: "\(name).json"),
            daemonID: id
        )
    }

    nonisolated static func offMain(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

final class SnapshotInbox: @unchecked Sendable {
    private let directory: URL
    private var handle: FileHandle?
    private var file: URL?

    init(directory: URL) {
        self.directory = directory
    }

    var isReceiving: Bool { handle != nil }

    func begin() throws {
        discard()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "incoming-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
        self.file = file
    }

    func append(_ data: Data) throws {
        try handle?.write(contentsOf: data)
    }

    func finish() throws -> URL? {
        try handle?.close()
        handle = nil
        return file
    }

    func discard() {
        try? handle?.close()
        handle = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
