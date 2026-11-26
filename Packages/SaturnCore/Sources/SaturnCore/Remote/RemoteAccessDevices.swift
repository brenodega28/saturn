import CryptoKit
import Darwin
import Foundation
import Synchronization

public struct RemoteDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date?

    public init(id: UUID, name: String, createdAt: Date, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

struct StoredRemoteDevice: Codable, Sendable, Hashable {
    var device: RemoteDevice
    var tokenHash: String
}

final class RemoteAccessDevices: Sendable {
    let url: URL
    private let now: @Sendable () -> Date
    private let stored: Mutex<[StoredRemoteDevice]>

    init(url: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.now = now
        let data = try? Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stored = Mutex(data.flatMap { try? decoder.decode([StoredRemoteDevice].self, from: $0) } ?? [])
    }

    var all: [RemoteDevice] {
        stored.withLock { $0.map(\.device) }
    }

    func add(name: String) throws -> (token: String, device: RemoteDevice) {
        let token = Self.makeToken()
        let device = RemoteDevice(id: UUID(), name: name, createdAt: now())
        try update { $0.append(StoredRemoteDevice(device: device, tokenHash: Self.hash(token))) }
        return (token, device)
    }

    func authenticate(_ token: String) -> RemoteDevice? {
        let hash = Self.hash(token)
        let seenAt = now()
        var found: RemoteDevice?
        try? update { devices in
            guard let index = devices.firstIndex(where: { $0.tokenHash == hash }) else { return }
            devices[index].device.lastSeenAt = seenAt
            found = devices[index].device
        }
        return found
    }

    @discardableResult
    func remove(_ id: UUID) throws -> Bool {
        var removed = false
        try update { devices in
            let before = devices.count
            devices.removeAll { $0.device.id == id }
            removed = devices.count != before
        }
        return removed
    }

    private func update(_ change: (inout [StoredRemoteDevice]) -> Void) throws {
        try stored.withLock { devices in
            let before = devices
            change(&devices)
            guard devices != before else { return }
            do {
                try write(devices)
            } catch {
                devices = before
                throw error
            }
        }
    }

    private func write(_ devices: [StoredRemoteDevice]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(devices)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CommandFailure(code: .failed, message: "Saturn couldn’t save the paired devices to \(url.path).")
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ChannelError.errno("rename \(url.path)")
        }
    }

    static func makeToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RemotePairing: Codable, Sendable, Hashable {
    public var code: String
    public var url: String
    public var expiresAt: Date
}

final class RemoteAccessPairing: Sendable {
    static let lifetime: TimeInterval = 5 * 60
    static let maximumAttempts = 5

    private struct Pending {
        var code: String
        var expiresAt: Date
        var failedAttempts = 0
    }

    private let now: @Sendable () -> Date
    private let pending = Mutex<Pending?>(nil)

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func begin() -> (code: String, expiresAt: Date) {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let expiresAt = now().addingTimeInterval(Self.lifetime)
        pending.withLock { $0 = Pending(code: code, expiresAt: expiresAt) }
        return (code, expiresAt)
    }

    func redeem(_ code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = now()
        return pending.withLock { pending in
            guard let current = pending else { return false }
            guard time < current.expiresAt else {
                pending = nil
                return false
            }
            guard current.code == code else {
                pending?.failedAttempts += 1
                if (pending?.failedAttempts ?? 0) >= Self.maximumAttempts { pending = nil }
                return false
            }
            pending = nil
            return true
        }
    }
}
