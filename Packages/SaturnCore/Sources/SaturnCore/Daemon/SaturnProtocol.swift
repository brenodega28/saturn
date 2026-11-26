import Foundation
import GRDB

public typealias DaemonID = UUID

public enum SaturnProtocol {
    public static let version = 1
    public static let buildVersion = "1.0.0"
}

public struct DaemonIdentity: Codable, Sendable, Hashable {
    public var id: DaemonID
    public var name: String
    public var protocolVersion: Int

    public init(id: DaemonID, name: String, protocolVersion: Int = SaturnProtocol.version) {
        self.id = id
        self.name = name
        self.protocolVersion = protocolVersion
    }
}

public enum DBValue: Codable, Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .real(value)
        case .string(let value): self = .text(value)
        case .blob(let value): self = .blob(value)
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .integer(let value): value.databaseValue
        case .real(let value): value.databaseValue
        case .text(let value): value.databaseValue
        case .blob(let value): value.databaseValue
        }
    }

    private enum CodingKeys: String, CodingKey { case i, r, t, b }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Int64.self, forKey: .i) {
            self = .integer(value)
        } else if let value = try container.decodeIfPresent(Double.self, forKey: .r) {
            self = .real(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .t) {
            self = .text(value)
        } else if let value = try container.decodeIfPresent(Data.self, forKey: .b) {
            self = .blob(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .null = self {
            var single = encoder.singleValueContainer()
            try single.encodeNil()
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: break
        case .integer(let value): try container.encode(value, forKey: .i)
        case .real(let value): try container.encode(value, forKey: .r)
        case .text(let value): try container.encode(value, forKey: .t)
        case .blob(let value): try container.encode(value, forKey: .b)
        }
    }
}

public enum ChangeOperation: String, Codable, Sendable {
    case upsert
    case delete
}

public struct RowChange: Codable, Sendable, Hashable {
    public var seq: Int64
    public var table: String
    public var op: ChangeOperation
    public var rowID: Int64
    public var row: [String: DBValue]?

    public init(seq: Int64, table: String, op: ChangeOperation, rowID: Int64, row: [String: DBValue]?) {
        self.seq = seq
        self.table = table
        self.op = op
        self.rowID = rowID
        self.row = row
    }
}

public struct Hello: Codable, Sendable {
    public var clientID: UUID
    public var protocolVersion: Int
    public var daemonID: DaemonID?
    public var lastSeq: Int64?

    public init(clientID: UUID, protocolVersion: Int = SaturnProtocol.version, daemonID: DaemonID? = nil, lastSeq: Int64? = nil) {
        self.clientID = clientID
        self.protocolVersion = protocolVersion
        self.daemonID = daemonID
        self.lastSeq = lastSeq
    }
}

public struct Welcome: Codable, Sendable {
    public var daemon: DaemonIdentity
    public var protocolVersion: Int
    public var buildVersion: String
}

public enum RefusalCode: String, Codable, Sendable {
    case daemonTooOld
    case clientTooOld
    case badRequest
}

public struct Refusal: Codable, Sendable, Error, LocalizedError {
    public var code: RefusalCode
    public var message: String
    public var daemonProtocolVersion: Int

    public var errorDescription: String? { message }
}

public enum FileKind: String, Codable, Sendable {
    case transcript
    case evidence
    case specDraft
    case attachment
    case agentFile
}

public struct FileRequest: Codable, Sendable {
    public var requestID: UUID
    public var kind: FileKind
    public var id: String
    public var offset: Int64
    public var follow: Bool

    public init(requestID: UUID = UUID(), kind: FileKind, id: String, offset: Int64 = 0, follow: Bool = false) {
        self.requestID = requestID
        self.kind = kind
        self.id = id
        self.offset = offset
        self.follow = follow
    }
}

public struct FileChunk: Codable, Sendable {
    public var requestID: UUID
    public var offset: Int64
    public var data: Data
    public var end: Bool
    public var error: String?
    public var caughtUp: Bool = false
}

public struct CommandEnvelope: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var args: Data

    public init(id: UUID = UUID(), name: String, args: Data) {
        self.id = id
        self.name = name
        self.args = args
    }
}

public enum CommandErrorCode: String, Codable, Sendable {
    case alreadyAnswered
    case notFound
    case unknownCommand
    case invalidArguments
    case failed
    case forbidden
}

public struct CommandFailure: Codable, Sendable, Error, LocalizedError, Equatable {
    public var code: CommandErrorCode
    public var message: String

    public init(code: CommandErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func alreadyAnswered(_ what: String) -> CommandFailure {
        CommandFailure(code: .alreadyAnswered, message: "\(what) was already answered.")
    }

    public static func notFound(_ what: String) -> CommandFailure {
        CommandFailure(code: .notFound, message: "\(what) no longer exists.")
    }
}

public struct ResultEnvelope: Codable, Sendable {
    public var id: UUID
    public var ok: Data?
    public var error: CommandFailure?
}

public struct SnapshotHeader: Codable, Sendable {
    public var seq: Int64
    public var size: Int64
}

public struct SnapshotChunk: Codable, Sendable {
    public var data: Data
}

public struct ResyncNotice: Codable, Sendable {
    public var oldestSeq: Int64
}

public struct ChangeBatch: Codable, Sendable {
    public var changes: [RowChange]
    public var seq: Int64
}

public enum DaemonEvent: Codable, Sendable, Hashable {
    case leadTurnEnded(taskId: Int64)
    case worktreeRemoving(path: String)
    case agentReplied(agentId: Int64)
    case specDrafted(projectId: Int64, taskId: Int64, path: String)
    case specReviewEnded(taskId: Int64)
    case readChat(relayID: UUID, daemon: DaemonID, request: ChatReadRequest)
    case shuttingDown
}

public enum ProtocolMessage: Codable, Sendable {
    case event(DaemonEvent)
    case hello(Hello)
    case welcome(Welcome)
    case refused(Refusal)
    case resync(ResyncNotice)
    case snapshotBegin(SnapshotHeader)
    case snapshotChunk(SnapshotChunk)
    case snapshotEnd(SnapshotHeader)
    case changes(ChangeBatch)
    case live(LiveState)
    case command(CommandEnvelope)
    case result(ResultEnvelope)
    case file(FileRequest)
    case fileCancel(FileRequest)
    case fileChunk(FileChunk)
    case bye

    public static func encode(_ message: ProtocolMessage) throws -> Data {
        try encoder.encode(message)
    }

    public static func decode(_ line: Data) throws -> ProtocolMessage {
        try decoder.decode(ProtocolMessage.self, from: line)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
