import Darwin
import Foundation
import HTTPTypes
import HummingbirdWSClient
import Logging
import NIOWebSocket
import Testing
@testable import SaturnCore

enum RemoteTestError: Error {
    case timedOut(String)
    case closed
}

@MainActor
final class RemoteTestSocket {
    nonisolated static let maximumSize = 64 * 1024 * 1024

    private let outgoing: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.Iterator
    private let connection: Task<WebSocketCloseFrame?, any Error>
    private(set) var frames: [String] = []

    init(url: String, headers: HTTPFields = [:]) {
        let (incoming, incomingContinuation) = AsyncStream.makeStream(of: String.self)
        let (outbound, outgoingContinuation) = AsyncStream.makeStream(of: String.self)
        outgoing = outgoingContinuation
        iterator = incoming.makeAsyncIterator()
        var logger = Logger(label: "remote-test-socket")
        logger.logLevel = .critical
        let configuration = WebSocketClientConfiguration(maxFrameSize: Self.maximumSize, additionalHeaders: headers)
        connection = Task.detached {
            defer { incomingContinuation.finish() }
            return try await WebSocketClient.connect(url: url, configuration: configuration, logger: logger) { inbound, writer, _ in
                let sender = Task {
                    for await text in outbound { try await writer.write(.text(text)) }
                    try? await writer.close(.normalClosure, reason: nil)
                }
                for try await message in inbound.messages(maxSize: Self.maximumSize) {
                    if case .text(let text) = message { incomingContinuation.yield(text) }
                }
                sender.cancel()
            }
        }
    }

    func send(_ message: ProtocolMessage) throws {
        outgoing.yield(String(decoding: try ProtocolMessage.encode(message), as: UTF8.self))
    }

    func sendRaw(_ text: String) {
        outgoing.yield(text)
    }

    func close() {
        outgoing.finish()
    }

    func closeCode(timeout: Duration = .seconds(10)) async throws -> WebSocketErrorCode? {
        let connection = connection
        return try await withTimeout(timeout, "close") { try await connection.value?.closeCode }
    }

    func next(timeout: Duration = .seconds(15)) async throws -> ProtocolMessage {
        let text = try await nextText(timeout: timeout)
        return try ProtocolMessage.decode(Data(text.utf8))
    }

    func nextText(timeout: Duration = .seconds(15)) async throws -> String {
        let timer = Task { @MainActor [outgoing] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { outgoing.finish() }
        }
        defer { timer.cancel() }
        var reader = iterator
        let next = await reader.next(isolation: #isolation)
        iterator = reader
        guard let text = next else { throw RemoteTestError.closed }
        frames.append(text)
        return text
    }

    @discardableResult
    func handshake(daemonID: DaemonID? = nil, lastSeq: Int64? = nil) async throws -> [ProtocolMessage] {
        try send(.hello(Hello(clientID: UUID(), daemonID: daemonID, lastSeq: lastSeq)))
        var messages: [ProtocolMessage] = []
        while true {
            let message = try await next()
            messages.append(message)
            if case .live = message { return messages }
            if case .refused = message { return messages }
        }
    }

    func perform<C: DaemonCommand>(_ command: C) async throws -> ResultEnvelope {
        let envelope = try CommandCoding.envelope(command)
        try send(.command(envelope))
        while true {
            if case .result(let result) = try await next(), result.id == envelope.id { return result }
        }
    }
}

func withTimeout<T: Sendable>(_ timeout: Duration, _ what: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RemoteTestError.timedOut(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

enum RemoteTestHTTP {
    static func pair(port: Int, code: String, name: String? = nil) async throws -> (status: Int, body: [String: String]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(code: code, name: name))
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    static func get(port: Int, path: String) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }
}

enum RemoteTestNetwork {
    static func freePort() -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    static func listeningAddresses(port: Int) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }
            .map { line in
                let name = line.dropFirst()
                return String(name[..<(name.lastIndex(of: ":") ?? name.endIndex)])
            }
    }
}

@MainActor
extension DaemonHarness {
    var remote: RemoteAccessServer { host.server!.remoteAccess }

    func enableRemoteAccess() async throws -> Int {
        let status = try await host.perform(RemoteAccessCommands.SetEnabled(enabled: true, port: 0))
        return status.port
    }

    func remoteSocket(port: Int, token: String?) -> RemoteTestSocket {
        RemoteTestSocket(url: "ws://127.0.0.1:\(port)/ws" + (token.map { "?token=\($0)" } ?? ""))
    }

    func pairedToken(_ name: String = "Phone") throws -> (token: String, device: RemoteDevice) {
        try remote.gateway.devices.add(name: name)
    }
}

@Suite struct RemoteAccessTestSupportTests {
    @Test func lsofParsingReadsTheListenAddress() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let port = RemoteTestNetwork.freePort()
        address.sin_port = UInt16(port).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(bound == 0)
        #expect(Darwin.listen(descriptor, 1) == 0)
        #expect(try RemoteTestNetwork.listeningAddresses(port: port) == ["127.0.0.1"])
    }
}
