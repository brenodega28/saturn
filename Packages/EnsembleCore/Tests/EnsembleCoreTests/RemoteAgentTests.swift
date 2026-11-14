import Foundation
import Testing
@testable import EnsembleCore

@Suite struct RemoteAgentLaunchTests {
    struct Fixture {
        let host: FakeSSHHost
        let worktree: URL
        let program: URL
        let record: URL
        let remote: RemoteAgentHost

        static func make() throws -> Fixture {
            let host = try FakeSSHHost()
            let worktree = host.home.appending(path: "repo/.crew/builder 1", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            let record = host.root.appending(path: "record.txt")
            let program = host.root.appending(path: "fake-claude")
            let script = """
            #!/bin/sh
            {
              echo "cwd=$(pwd)"
              echo "args=$*"
              echo "key=${ANTHROPIC_API_KEY:-none}"
              echo "token=${ANTHROPIC_AUTH_TOKEN:-none}"
              echo "port=${PORT:-none}"
              echo "path=${LEAKED:-none}"
              IFS= read -r first
              echo "stdin=$first"
            } > \(ShellQuote.quote(record.path))
            [ -f \(ShellQuote.quote(host.root.appending(path: "sleep").path)) ] && exec sleep 30
            exit 0
            """
            try script.write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            let client = SSHClient(destination: "devbox", executable: host.executable, runner: CommandRunner(environment: ["ANTHROPIC_AUTH_TOKEN": "host-token", "PATH": "/usr/bin:/bin"]), controlDirectory: nil)
            let remote = RemoteAgentHost(client: client, claudePath: program.path, home: host.home.path, localPort: 4100, relayPort: 5100)
            return Fixture(host: host, worktree: worktree, program: program, record: record, remote: remote)
        }

        func launch(apiKey: String?, environment: [String: String] = [:]) -> ClaudeLaunch {
            ClaudeLaunch(
                executable: URL(fileURLWithPath: "/usr/local/bin/claude"), worktree: worktree, session: .new("s1"), model: "sonnet",
                systemPrompt: "Be careful", environment: environment.merging(["LEAKED": "/Users/me/secret-path"]) { a, _ in a },
                remote: RemoteAgentLaunch(host: remote, stateDirectory: remote.stateDirectory(forAgent: 7), mcpConfiguration: #"{"mcpServers":{}}"#, apiKey: apiKey)
            )
        }

        func recorded() async throws -> [String: String] {
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: record.path) { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(100))
            let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
            return Dictionary(lines.compactMap { line in line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } }) { a, _ in a }
        }
    }

    @Test func runsClaudeOnTheHostWithThePreambleAndOnlyForwardedVariables() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        let launch = f.launch(apiKey: "sk-test", environment: ["PORT": "4321"])
        #expect(!launch.invocation.arguments.joined(separator: " ").contains("sk-test"))

        let (handle, output) = try ClaudeProcessLauncher().launch(launch)
        try handle.send(line: #"{"type":"user"}"#)
        handle.closeInput()
        var exit: Int32?
        for await item in output { if case .exited(let code, _) = item { exit = code } }

        let record = try await f.recorded()
        #expect(exit == 0)
        #expect(record["cwd"] == f.worktree.path)
        #expect(record["key"] == "sk-test")
        #expect(record["token"] == "none")
        #expect(record["port"] == "4321")
        #expect(record["path"] == "none")
        #expect(record["stdin"] == #"{"type":"user"}"#)
        #expect(record["args"]?.contains("--append-system-prompt Be careful") == true)
        #expect(record["args"]?.contains("Edit(/" + f.worktree.path + "/**)") == true)

        let state = f.remote.stateDirectory(forAgent: 7)
        #expect(try String(contentsOfFile: state + "/mcp.json", encoding: .utf8) == #"{"mcpServers":{}}"#)
        let permissions = try FileManager.default.attributesOfItem(atPath: state + "/mcp.json")[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func signInModeLeavesNoKeyAndAMissingWorktreeFailsClearly() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        let (handle, output) = try ClaudeProcessLauncher().launch(f.launch(apiKey: nil))
        handle.closeInput()
        for await _ in output {}
        #expect(try await f.recorded()["key"] == "none")

        try FileManager.default.removeItem(at: f.worktree)
        let (gone, goneOutput) = try ClaudeProcessLauncher().launch(f.launch(apiKey: nil))
        gone.closeInput()
        var failure: (Int32, String)?
        for await item in goneOutput { if case .exited(let code, let error) = item { failure = (code, error) } }
        #expect(failure?.0 == 3)
        #expect(failure?.1.contains("doesn’t exist on the host") == true)
    }

    @Test func terminatingSignalsTheProcessOnTheHost() async throws {
        let f = try Fixture.make()
        defer { f.host.remove() }
        try "".write(to: f.host.root.appending(path: "sleep"), atomically: true, encoding: .utf8)
        let (handle, output) = try ClaudeProcessLauncher().launch(f.launch(apiKey: nil))
        _ = try await f.recorded()
        let pidFile = f.remote.stateDirectory(forAgent: 7) + "/pid"
        let pid = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)

        handle.terminate()
        for await _ in output {}
        for _ in 0..<40 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(kill(pid, 0) != 0)
    }

    @Test func relaysOnlyTheLocalServerPort() {
        let host = RemoteAgentHost(client: SSHClient(destination: "devbox", controlDirectory: nil), claudePath: "claude", home: "/home/me", localPort: 4100, relayPort: 5100)
        #expect(host.relay(URL(string: "http://127.0.0.1:4100/hook/abc")!).absoluteString == "http://127.0.0.1:5100/hook/abc")
        #expect(host.relay(URL(string: "http://127.0.0.1:9999/x")!).absoluteString == "http://127.0.0.1:9999/x")
        #expect(host.stateDirectory(forAgent: 3) == "/home/me/.cache/ensemble/agents/3")
    }
}

@Suite struct RemoteCheckTests {
    @Test func runsChecksOnTheHostWithVariablesAndTimesOut() async throws {
        let host = try FakeSSHHost()
        defer { host.remove() }
        let worktree = host.home.appending(path: "wt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let logs = host.root.appending(path: "logs", directoryHint: .isDirectory)
        let client = SSHClient(destination: "devbox", executable: host.executable, runner: CommandRunner(environment: ["LEAKED": "mac"]), controlDirectory: nil)
        var runner = CheckRunner(environment: ["LEAKED": "mac"], killGracePeriod: .milliseconds(200), minute: .milliseconds(1500))
        runner.remote = RemoteAgentHost(client: client, claudePath: "claude", home: host.home.path, localPort: 1, relayPort: 1)

        let results = await runner.run([
            CheckDefinition(name: "where", kind: .test, command: "echo \"dir=$(basename \"$PWD\") port=$PORT leaked=${LEAKED:-none}\""),
            CheckDefinition(name: "fails", kind: .lint, command: "echo boom; exit 4"),
            CheckDefinition(name: "hangs", kind: .test, command: "sleep 30", timeoutMinutes: 1),
        ], in: worktree, variables: ["PORT": "4321"], logDirectory: logs)

        #expect(results.map(\.status) == [.passed, .failed, .timedOut])
        #expect(results[0].output == "dir=wt port=4321 leaked=none")
        #expect(results[1].exitCode == 4)
        #expect(results[1].output == "boom")
    }
}

