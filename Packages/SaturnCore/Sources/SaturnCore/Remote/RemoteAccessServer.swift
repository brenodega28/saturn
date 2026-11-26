import Darwin
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import ServiceLifecycle
import Synchronization

public struct RemoteAccessSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var port: Int

    public init(enabled: Bool = false, port: Int = RemoteAccessServer.defaultPort) {
        self.enabled = enabled
        self.port = port
    }
}

public struct RemoteAccessStatus: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var port: Int
    public var addresses: [String]
    public var pairedDevices: [RemoteDevice]
}

@MainActor
public final class RemoteAccessServer {
    public nonisolated static let defaultPort = 7878
    public nonisolated static let unauthorizedCloseCode: UInt16 = 4401

    let gateway: RemoteAccessGateway
    private let addressSource: @Sendable () -> [String]
    private var listeners: [RemoteAccessListener] = []
    public private(set) var addresses: [String] = []
    public private(set) var port: Int?

    public var isListening: Bool { !listeners.isEmpty }
    public var devices: [RemoteDevice] { gateway.devices.all }

    init(
        devicesFile: URL,
        webRoot: URL? = RemoteAccessServer.bundledWebRoot,
        now: @escaping @Sendable () -> Date = Date.init,
        addresses: @escaping @Sendable () -> [String] = RemoteAccessAddresses.current,
        accept: @escaping @MainActor @Sendable (LineChannel, UUID) -> Void
    ) {
        gateway = RemoteAccessGateway(
            devices: RemoteAccessDevices(url: devicesFile, now: now),
            pairing: RemoteAccessPairing(now: now),
            webRoot: webRoot,
            accept: accept
        )
        addressSource = addresses
    }

    nonisolated static var bundledWebRoot: URL? {
        Bundle.module.resourceURL?.appending(path: "Remote/dist", directoryHint: .isDirectory)
    }

    public func start(port requested: Int) async throws {
        await stop()
        let candidates = addressSource().filter(RemoteAccessAddresses.isAllowed)
        let others = candidates.filter { $0 != RemoteAccessAddresses.loopback }
        let (loopback, bound) = try await gateway.listen(on: RemoteAccessAddresses.loopback, port: requested)
        listeners = [loopback]
        addresses = [RemoteAccessAddresses.loopback]
        port = bound
        for address in others {
            guard let (listener, _) = try? await gateway.listen(on: address, port: bound) else { continue }
            listeners.append(listener)
            addresses.append(address)
        }
    }

    public func stop() async {
        let running = listeners
        shutdown()
        for listener in running { await listener.finished() }
    }

    func shutdown() {
        gateway.bridges.closeAll()
        listeners.forEach { $0.stop() }
        listeners = []
        addresses = []
        port = nil
    }

    func beginPairing() -> RemotePairing {
        let (code, expiresAt) = gateway.pairing.begin()
        let host = addresses.first(where: RemoteAccessAddresses.isTailscale) ?? RemoteAccessAddresses.loopback
        return RemotePairing(code: code, url: "http://\(host):\(port ?? Self.defaultPort)/#pair", expiresAt: expiresAt)
    }

    func revoke(_ deviceID: UUID) throws -> Bool {
        let removed = try gateway.devices.remove(deviceID)
        gateway.bridges.revoke(deviceID)
        return removed
    }
}

struct PairRequest: Codable, Sendable {
    var code: String
    var name: String?
}

struct PairResponse: ResponseEncodable, Sendable {
    var token: String
    var deviceID: String
}

final class RemoteAccessGateway: Sendable {
    let devices: RemoteAccessDevices
    let pairing: RemoteAccessPairing
    let bridges = RemoteAccessBridges()
    private let webRoot: URL?
    private let accept: @MainActor @Sendable (LineChannel, UUID) -> Void
    private let logger: Logger = {
        var logger = Logger(label: "saturnd.remote-access")
        logger.logLevel = .warning
        return logger
    }()

    static let maximumMessageSize = 64 * 1024 * 1024

    init(devices: RemoteAccessDevices, pairing: RemoteAccessPairing, webRoot: URL?, accept: @escaping @MainActor @Sendable (LineChannel, UUID) -> Void) {
        self.devices = devices
        self.pairing = pairing
        self.webRoot = webRoot
        self.accept = accept
    }

    func listen(on address: String, port: Int) async throws -> (RemoteAccessListener, Int) {
        let router = makeRouter()
        let ready = ReadySignal()
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: router,
                configuration: .init(ws: .init(maxFrameSize: Self.maximumMessageSize, autoPing: .enabled(timePeriod: .seconds(30))))
            ),
            configuration: ApplicationConfiguration(address: .hostname(address, port: port), serverName: "saturnd"),
            onServerRunning: { channel in ready.finish(.success(channel.localAddress?.port ?? port)) },
            logger: logger
        )
        let group = ServiceGroup(configuration: .init(services: [app], logger: logger))
        let task = Task {
            do {
                try await group.run()
                ready.finish(.failure(ChannelError.closed))
            } catch {
                ready.finish(.failure(error))
            }
        }
        let listener = RemoteAccessListener(group: group, task: task)
        do {
            return (listener, try await ready.value())
        } catch {
            listener.stop()
            await listener.finished()
            throw CommandFailure(code: .failed, message: "Saturn couldn’t listen on \(address):\(port): \(error)")
        }
    }

    private func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        if let webRoot, FileManager.default.fileExists(atPath: webRoot.appending(path: "index.html").path) {
            router.add(middleware: FileMiddleware(webRoot.path, searchForIndexHtml: true, logger: logger))
        } else {
            router.get("/") { _, _ in Self.placeholder }
        }
        router.post("pair") { [self] request, context -> Response in
            let body = try await request.decode(as: PairRequest.self, context: context)
            guard pairing.redeem(body.code) else {
                return Response(status: .unauthorized, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalidCode"}"#)))
            }
            let name = body.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let (token, device) = try devices.add(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.deviceName(userAgent: request.headers[.userAgent]))
            return try PairResponse(token: token, deviceID: device.id.uuidString).response(from: request, context: context)
        }
        router.ws("ws") { [self] inbound, outbound, context in
            await serve(inbound: inbound, outbound: outbound, request: context.request)
        }
        return router
    }

    private func serve(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, request: Request) async {
        guard let token = Self.token(in: request), let device = devices.authenticate(token) else {
            try? await outbound.close(.unknown(RemoteAccessServer.unauthorizedCloseCode), reason: "Unauthorized")
            return
        }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            try? await outbound.close(.unexpectedServerError, reason: "Saturn couldn’t open a session")
            return
        }
        let bridge = LineChannel(socket: pair[1])
        let link = bridges.add(device: device.id, channel: bridge)
        defer { bridges.remove(link) }
        await accept(LineChannel(socket: pair[0]), device.id)
        let pump = Task {
            for await line in bridge.lines {
                do {
                    try await outbound.write(.text(String(decoding: line, as: UTF8.self)))
                } catch {
                    break
                }
            }
            bridge.close()
            if link.isRevoked {
                try? await outbound.close(.unknown(RemoteAccessServer.unauthorizedCloseCode), reason: "Revoked")
            } else {
                try? await outbound.close(.normalClosure, reason: nil)
            }
        }
        do {
            for try await message in inbound.messages(maxSize: Self.maximumMessageSize) {
                guard case .text(let text) = message else { continue }
                var line = Data(text.utf8).map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 }
                line.append(0x0A)
                try bridge.sendRaw(Data(line))
            }
        } catch {}
        bridge.close()
        await pump.value
    }

    static func token(in request: Request) -> String? {
        if let header = request.headers[.authorization], header.lowercased().hasPrefix("bearer ") {
            let token = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { return token }
        }
        return request.uri.queryParameters["token"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func deviceName(userAgent: String?) -> String {
        guard let userAgent else { return "Browser" }
        for (marker, name) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"), ("Macintosh", "Mac"), ("Windows", "Windows PC"), ("Linux", "Linux")]
        where userAgent.contains(marker) {
            return name
        }
        return "Browser"
    }

    static var placeholder: Response {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\
        <title>Saturn Remote</title></head><body style="font-family:-apple-system,system-ui,sans-serif;padding:24px">\
        <h1>Web client not built</h1><p>This saturnd has no Saturn Remote web client. Run scripts/build-remote.sh and rebuild Saturn.</p>\
        </body></html>
        """
        return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(string: html)))
    }
}

struct RemoteAccessListener: Sendable {
    let group: ServiceGroup
    let task: Task<Void, Never>

    func stop() {
        let task = task
        Task {
            await group.triggerGracefulShutdown()
            try? await Task.sleep(for: .seconds(2))
            task.cancel()
        }
    }

    func finished() async {
        await task.value
    }
}

final class RemoteAccessLink: Sendable {
    let id = UUID()
    let device: UUID
    let channel: LineChannel
    private let revoked = Mutex(false)

    init(device: UUID, channel: LineChannel) {
        self.device = device
        self.channel = channel
    }

    var isRevoked: Bool { revoked.withLock { $0 } }

    func revoke() {
        revoked.withLock { $0 = true }
        channel.close()
    }
}

final class RemoteAccessBridges: Sendable {
    private let links = Mutex<[UUID: RemoteAccessLink]>([:])

    func add(device: UUID, channel: LineChannel) -> RemoteAccessLink {
        let link = RemoteAccessLink(device: device, channel: channel)
        links.withLock { $0[link.id] = link }
        return link
    }

    func remove(_ link: RemoteAccessLink) {
        _ = links.withLock { $0.removeValue(forKey: link.id) }
    }

    var count: Int { links.withLock { $0.count } }

    func revoke(_ device: UUID) {
        let matching = links.withLock { $0.values.filter { $0.device == device } }
        matching.forEach { $0.revoke() }
    }

    func closeAll() {
        let all = links.withLock { Array($0.values) }
        all.forEach { $0.channel.close() }
    }
}

final class ReadySignal: Sendable {
    private let state = Mutex<(result: Result<Int, any Error>?, waiter: CheckedContinuation<Int, any Error>?)>((nil, nil))

    func finish(_ result: Result<Int, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Int, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Int, any Error>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
