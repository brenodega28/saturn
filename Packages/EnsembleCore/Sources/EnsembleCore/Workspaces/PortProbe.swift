import Darwin
import Foundation

public enum PortProbe {
    public static func isListening(port: Int) async -> Bool {
        guard port > 0, port <= PortAllocator.highestPort else { return false }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: connects(ipv4: port) || connects(ipv6: port))
            }
        }
    }

    static func connects(ipv4 port: Int) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(family: AF_INET, address: $0, length: socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    static func connects(ipv6 port: Int) -> Bool {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(family: AF_INET6, address: $0, length: socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    static let connectTimeoutMilliseconds: Int32 = 500

    private static func connect(family: Int32, address: UnsafePointer<sockaddr>, length: socklen_t) -> Bool {
        let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        if Darwin.connect(descriptor, address, length) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&request, 1, connectTimeoutMilliseconds) == 1 else { return false }
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else { return false }
        return failure == 0
    }
}
