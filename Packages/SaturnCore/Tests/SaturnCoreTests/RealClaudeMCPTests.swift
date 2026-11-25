import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SATURN_REAL_CLAUDE"] == "1"))
struct RealClaudeMCPTests {
    @Test(.timeLimit(.minutes(3))) func realClaudeCallsSubmitResult() async throws {
        let sink = RecordingSink()
        let server = try await SaturnMCPServer.start(sink: sink)
        defer { server.stop() }
        let endpoint = server.register(agent: 42, tools: [.submitResult])

        let workspace = FileManager.default.temporaryDirectory.appending(path: "saturn-real-claude-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let executable = ProcessInfo.processInfo.environment["SATURN_CLAUDE_PATH"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            environment.removeValue(forKey: key)
        }

        let arguments = [
            "-p", "Call the submit_result tool with summary set to exactly hello. Do nothing else, then stop.",
            "--output-format", "stream-json",
            "--verbose",
            "--model", "haiku",
            "--permission-mode", "dontAsk",
            "--setting-sources", "project",
        ] + (try endpoint.launchArguments(configDirectory: workspace.appending(path: "mcp")))
            + ["--allowedTools"] + endpoint.allowedTools

        let result = try await CommandRunner(environment: environment).run(executable, arguments, in: workspace)

        if let transcript = ProcessInfo.processInfo.environment["SATURN_REAL_CLAUDE_TRANSCRIPT"] {
            try result.standardOutput.write(toFile: transcript, atomically: true, encoding: .utf8)
        }
        let events = result.standardOutput.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        let initEvent = events.first { $0["type"]?.string == "system" && $0["subtype"]?.string == "init" }
        print("system/init mcp_servers:", initEvent?["mcp_servers"]?.compactJSON ?? "missing")
        print("apiKeySource:", initEvent?["apiKeySource"]?.string ?? "missing")

        #expect(result.succeeded, "\(result.standardError)")
        let servers = initEvent?["mcp_servers"]?.array ?? []
        #expect(servers.map { $0["name"]?.string } == ["saturn"])
        #expect(servers.map { $0["status"]?.string } == ["connected"])
        #expect(initEvent?["apiKeySource"] == .string("none"))
        #expect(sink.received.map(\.agentID) == [42])
        #expect(sink.received.map(\.message) == [.result("hello")])
    }
}
