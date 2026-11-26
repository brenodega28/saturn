import Darwin
import Foundation

public enum RemoteAccessAddresses {
    public static let loopback = "127.0.0.1"

    public static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    public static func isAllowed(_ address: String) -> Bool {
        address == loopback || isTailscale(address)
    }

    struct InterfaceAddress: Equatable {
        var interface: String
        var address: String
    }

    static func tailscale(in interfaces: [InterfaceAddress]) -> [String] {
        var found: [String] = []
        for entry in interfaces where entry.interface.hasPrefix("utun") && isTailscale(entry.address) && !found.contains(entry.address) {
            found.append(entry.address)
        }
        return found
    }

    public static func tailscale() -> [String] {
        tailscale(in: ipv4Interfaces())
    }

    static func ipv4Interfaces() -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var found: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append(InterfaceAddress(interface: String(cString: pointer.pointee.ifa_name), address: text))
        }
        return found
    }

    public static func current() -> [String] {
        [loopback] + tailscale()
    }
}
