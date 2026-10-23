import Foundation
import Network
import Synchronization

public enum MCPServerError: Error, LocalizedError, Equatable {
    case listenerFailed(String)
    case stopped

    public var errorDescription: String? {
        switch self {
        case .listenerFailed(let reason): "The Ensemble MCP server could not start: \(reason)"
        case .stopped: "The Ensemble MCP server stopped before it was ready."
        }
    }
}

public final class EnsembleMCPServer: Sendable {
    public let port: UInt16
    public let maximumBodySize: Int

    private let listener: NWListener
    private let registry: MCPTokenRegistry
    private let handler: MCPRequestHandler
    private let queue: DispatchQueue
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])

    private init(port: UInt16, maximumBodySize: Int, listener: NWListener, registry: MCPTokenRegistry, handler: MCPRequestHandler, queue: DispatchQueue) {
        self.port = port
        self.maximumBodySize = maximumBodySize
        self.listener = listener
        self.registry = registry
        self.handler = handler
        self.queue = queue
    }

    public static func start(sink: any HandoffSink, maximumBodySize: Int = 16 * 1024 * 1024) async throws -> EnsembleMCPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPServerError.listenerFailed(error.localizedDescription)
        }
        let registry = MCPTokenRegistry()
        let handler = MCPRequestHandler(registry: registry, sink: sink)
        let queue = DispatchQueue(label: "ensemble.mcp.server")
        let pending = PendingServer()

        listener.newConnectionHandler = { connection in
            pending.accept(connection)
        }

        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let readiness = OneShot(continuation)
            let finish = readiness.resume
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        finish(.success(port))
                    } else {
                        finish(.failure(MCPServerError.listenerFailed("no port was assigned")))
                    }
                case .failed(let error):
                    finish(.failure(MCPServerError.listenerFailed(error.localizedDescription)))
                    listener.cancel()
                case .cancelled:
                    finish(.failure(MCPServerError.stopped))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        let server = EnsembleMCPServer(port: port, maximumBodySize: maximumBodySize, listener: listener, registry: registry, handler: handler, queue: queue)
        pending.attach(server)
        return server
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(MCPRequestHandler.pathPrefix)") ?? URL(filePath: "/")
    }

    public func register(agent: Int64, tools: Set<HandoffTool>) -> MCPEndpoint {
        let token = registry.issue(agentID: agent, tools: tools)
        return MCPEndpoint(agentID: agent, token: token, url: baseURL.appending(path: token), tools: tools)
    }

    public func revoke(token: String) {
        registry.revoke(token)
    }

    public func revokeAll(agent: Int64) {
        registry.revokeAll(agentID: agent)
    }

    public func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let open = connections.withLock { open in
            defer { open.removeAll() }
            return Array(open.values)
        }
        open.forEach { $0.cancel() }
    }

    fileprivate func serve(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        let session = MCPConnection(connection: connection, handler: handler, maximumBodySize: maximumBodySize)
        let queue = queue
        Task { [weak self] in
            await session.run(on: queue)
            self?.connections.withLock { _ = $0.removeValue(forKey: key) }
        }
    }
}

private final class OneShot<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ result: Result<Value, any Error>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }
}

private final class PendingServer: Sendable {
    private enum State {
        case waiting([NWConnection])
        case attached(EnsembleMCPServer)
    }

    private let state = Mutex<State>(.waiting([]))

    func accept(_ connection: NWConnection) {
        let server: EnsembleMCPServer? = state.withLock { state in
            switch state {
            case .waiting(let queued):
                state = .waiting(queued + [connection])
                return nil
            case .attached(let server):
                return server
            }
        }
        server?.serve(connection)
    }

    func attach(_ server: EnsembleMCPServer) {
        let queued: [NWConnection] = state.withLock { state in
            defer { state = .attached(server) }
            if case .waiting(let queued) = state { return queued }
            return []
        }
        queued.forEach(server.serve)
    }
}

private struct MCPConnection: Sendable {
    let connection: NWConnection
    let handler: MCPRequestHandler
    let maximumBodySize: Int

    func run(on queue: DispatchQueue) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        var parser = HTTPRequestParser(maximumBodySize: maximumBodySize)
        while true {
            do {
                while let request = try parser.nextRequest() {
                    let response = await handler.respond(to: request)
                    let keepAlive = request.keepsConnectionAlive
                    try await send(response.serialized(keepAlive: keepAlive))
                    if !keepAlive { return }
                }
            } catch let error as HTTPParseError {
                try? await send(error.response.serialized(keepAlive: false))
                return
            } catch {
                return
            }
            guard let chunk = await receive() else { return }
            parser.append(chunk)
        }
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
