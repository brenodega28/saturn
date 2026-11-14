import Foundation

public protocol DaemonCommand: Codable, Sendable {
    associatedtype Response: Codable & Sendable = Done
    static var name: String { get }
}

public struct Done: Codable, Sendable, Equatable {
    public init() {}
}

public enum CommandCoding {
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

    public static func envelope<C: DaemonCommand>(_ command: C) throws -> CommandEnvelope {
        CommandEnvelope(name: C.name, args: try encoder.encode(command))
    }

    public static func response<C: DaemonCommand>(of type: C.Type, from result: ResultEnvelope) throws -> C.Response {
        if let error = result.error { throw error }
        guard let data = result.ok else { throw CommandFailure(code: .failed, message: "The daemon sent an empty result.") }
        return try decoder.decode(C.Response.self, from: data)
    }
}

@MainActor
final class CommandRouter {
    private var handlers: [String: @MainActor (Data) async throws -> Data] = [:]

    func register<C: DaemonCommand>(_ type: C.Type, _ handler: @escaping @MainActor (C) async throws -> C.Response) {
        handlers[C.name] = { data in
            let command: C
            do {
                command = try CommandCoding.decoder.decode(C.self, from: data)
            } catch {
                throw CommandFailure(code: .invalidArguments, message: "Couldn’t read the arguments of \(C.name): \(error.localizedDescription)")
            }
            return try CommandCoding.encoder.encode(try await handler(command))
        }
    }

    var names: [String] { handlers.keys.sorted() }

    func handle(_ envelope: CommandEnvelope) async -> ResultEnvelope {
        guard let handler = handlers[envelope.name] else {
            return ResultEnvelope(id: envelope.id, ok: nil, error: CommandFailure(code: .unknownCommand, message: "This daemon doesn’t know the command \(envelope.name). Update the daemon."))
        }
        do {
            return ResultEnvelope(id: envelope.id, ok: try await handler(envelope.args), error: nil)
        } catch let failure as CommandFailure {
            return ResultEnvelope(id: envelope.id, ok: nil, error: failure)
        } catch {
            return ResultEnvelope(id: envelope.id, ok: nil, error: CommandFailure(code: .failed, message: error.localizedDescription))
        }
    }
}
