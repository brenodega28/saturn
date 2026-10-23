import Foundation
import Synchronization

@MainActor
public protocol HandoffSink: AnyObject, Sendable {
    func receive(_ message: HandoffMessage, from agentID: Int64) async throws -> String
}

public struct MCPEndpoint: Sendable, Hashable {
    public let agentID: Int64
    public let token: String
    public let url: URL
    public let tools: Set<HandoffTool>

    public init(agentID: Int64, token: String, url: URL, tools: Set<HandoffTool>) {
        self.agentID = agentID
        self.token = token
        self.url = url
        self.tools = tools
    }

    public var orderedTools: [HandoffTool] {
        HandoffTool.allCases.filter(tools.contains)
    }

    public var allowedTools: [String] {
        orderedTools.map(\.qualifiedName)
    }

    public var configuration: JSONValue {
        .object([
            "mcpServers": .object([
                HandoffTool.serverName: .object([
                    "type": .string("http"),
                    "url": .string(url.absoluteString),
                ]),
            ]),
        ])
    }

    public func configurationFile(in configDirectory: URL) -> URL {
        configDirectory.appending(path: "mcp-agent-\(agentID).json")
    }

    public func launchArguments(configDirectory: URL) throws -> [String] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = configurationFile(in: configDirectory)
        try Data(configuration.compactJSON.utf8).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return ["--mcp-config", file.path, "--strict-mcp-config"]
    }
}

struct MCPGrant: Sendable, Equatable {
    let agentID: Int64
    let tools: Set<HandoffTool>

    var orderedTools: [HandoffTool] {
        HandoffTool.allCases.filter(tools.contains)
    }
}

final class MCPTokenRegistry: Sendable {
    private let grants = Mutex<[String: MCPGrant]>([:])

    func issue(agentID: Int64, tools: Set<HandoffTool>) -> String {
        let token = Self.randomToken()
        grants.withLock { $0[token] = MCPGrant(agentID: agentID, tools: tools) }
        return token
    }

    func grant(for token: String) -> MCPGrant? {
        grants.withLock { $0[token] }
    }

    func revoke(_ token: String) {
        _ = grants.withLock { $0.removeValue(forKey: token) }
    }

    func revokeAll(agentID: Int64) {
        grants.withLock { grants in
            grants = grants.filter { $0.value.agentID != agentID }
        }
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
