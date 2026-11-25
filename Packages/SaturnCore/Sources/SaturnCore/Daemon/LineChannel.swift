import Darwin
import Foundation
import Synchronization

public enum ChannelError: Error, LocalizedError, Equatable {
    case closed
    case socketPathTooLong(String)
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .closed: "The connection to the Saturn daemon closed."
        case .socketPathTooLong(let path): "The daemon socket path is too long for macOS: \(path)"
        case .system(let message): message
        }
    }

    static func errno(_ action: String) -> ChannelError {
        .system("\(action): \(String(cString: strerror(Darwin.errno)))")
    }
}

public final class LineChannel: Sendable {
    public let lines: AsyncStream<Data>
    private let readDescriptor: Int32
    private let writeDescriptor: Int32
    private let ownsDescriptors: Bool
    private let writeLock = Mutex<Bool>(false)
    private let closedState = Mutex<Bool>(false)
    private let continuation: AsyncStream<Data>.Continuation
    private let onClose: Mutex<[@Sendable () -> Void]>

    public init(readDescriptor: Int32, writeDescriptor: Int32, ownsDescriptors: Bool = true) {
        self.readDescriptor = readDescriptor
        self.writeDescriptor = writeDescriptor
        self.ownsDescriptors = ownsDescriptors
        self.onClose = Mutex([])
        var captured: AsyncStream<Data>.Continuation!
        self.lines = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
        var on: Int32 = 1
        setsockopt(writeDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let thread = Thread { [self] in readLoop() }
        thread.name = "saturn.line-channel"
        thread.start()
    }

    public convenience init(socket: Int32) {
        self.init(readDescriptor: socket, writeDescriptor: socket)
    }

    public var isClosed: Bool { closedState.withLock { $0 } }

    public func whenClosed(_ action: @escaping @Sendable () -> Void) {
        let alreadyClosed = closedState.withLock { closed in
            if !closed { onClose.withLock { $0.append(action) } }
            return closed
        }
        if alreadyClosed { action() }
    }

    public func send(_ message: ProtocolMessage) throws {
        var data = try ProtocolMessage.encode(message)
        data.append(0x0A)
        try sendRaw(data)
    }

    public func sendRaw(_ data: Data) throws {
        try writeLock.withLock { _ in
            guard !isClosed else { throw ChannelError.closed }
            try data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(writeDescriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw ChannelError.closed
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
        }
    }

    public func close() {
        let wasOpen = closedState.withLock { closed -> Bool in
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        if ownsDescriptors {
            shutdown(readDescriptor, SHUT_RDWR)
            if writeDescriptor != readDescriptor { Darwin.close(writeDescriptor) }
        }
        continuation.finish()
        let actions = onClose.withLock { actions in
            defer { actions = [] }
            return actions
        }
        actions.forEach { $0() }
    }

    private func readLoop() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                if !line.isEmpty { continuation.yield(Data(line)) }
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        close()
        writeLock.withLock { _ in
            if ownsDescriptors { Darwin.close(readDescriptor) }
        }
    }
}

public enum UnixSocket {
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ChannelError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    public static func connect(path: String) throws -> Int32 {
        var address = try address(for: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ChannelError.errno("socket") }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let error = ChannelError.errno("connect \(path)")
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    public static func listen(path: String) throws -> Int32 {
        var address = try address(for: path)
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ChannelError.errno("socket") }
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0 else {
            let error = ChannelError.errno("bind \(path)")
            Darwin.close(descriptor)
            throw error
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 16) == 0 else {
            let error = ChannelError.errno("listen \(path)")
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }
}

public final class SocketListener: Sendable {
    public let path: String
    private let descriptor: Int32
    private let stopped = StopFlag()

    public init(path: String, accept: @escaping @Sendable (Int32) -> Void) throws {
        self.path = path
        self.descriptor = try UnixSocket.listen(path: path)
        let descriptor = self.descriptor
        let stopped = self.stopped
        let thread = Thread {
            while !stopped.isSet {
                let client = Darwin.accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if stopped.isSet {
                    Darwin.close(client)
                    break
                }
                accept(client)
            }
        }
        thread.name = "saturn.socket-listener"
        thread.start()
    }

    public func stop() {
        guard stopped.set() else { return }
        if let wake = try? UnixSocket.connect(path: path) { Darwin.close(wake) }
        Darwin.close(descriptor)
        unlink(path)
    }
}

final class StopFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() -> Bool {
        value.withLock { value in
            defer { value = true }
            return !value
        }
    }
}
