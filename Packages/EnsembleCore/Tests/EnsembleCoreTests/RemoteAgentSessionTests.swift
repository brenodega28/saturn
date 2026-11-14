import Foundation
import Testing
@testable import EnsembleCore

@Suite @MainActor struct RemoteAgentSessionTests {
    @MainActor struct Setup {
        let harness: AgentHarness
        let host: FakeSSHHost
        let destination: String
        let project: Project

        static func make(mode: String = "normal") async throws -> Setup {
            let harness = try await AgentHarness.make(mode: mode)
            let host = try FakeSSHHost()
            let destination = "fakehost-\(UUID().uuidString.lowercased())"
            SSHClient.executableOverrides.withLock { $0[destination] = host.executable }
            let remoteClaude = host.root.appending(path: "claude-on-host")
            try "#!/bin/sh\nFAKE_DIR=\(ShellQuote.quote(harness.bin.path)) exec \(ShellQuote.quote(harness.bin.appending(path: "claude").path)) \"$@\"\n"
                .write(to: remoteClaude, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remoteClaude.path)
            let client = SSHClient(destination: destination, executable: host.executable, controlDirectory: nil)
            let root = try await RemoteHost(client: client).repositoryRoot(containing: harness.repo.root.path)
            let project = try harness.database.openRemoteProject(path: root, host: destination)
            harness.runtime.remoteHostProvider = { _ in
                RemoteAgentHost(client: client, claudePath: remoteClaude.path, home: host.home.path, localPort: 1, relayPort: 1)
            }
            return Setup(harness: harness, host: host, destination: destination, project: project)
        }

        func stateDirectory(_ agent: Agent) -> String {
            host.home.path + "/.cache/ensemble/agents/\(agent.id!)"
        }

        func cleanUp() {
            SSHClient.executableOverrides.withLock { $0[destination] = nil }
            harness.cleanUp()
            host.remove()
        }
    }

    @Test func runsATurnOnTheHostInAWorktreeCreatedThere() async throws {
        let setup = try await Setup.make()
        defer { setup.cleanUp() }
        let runtime = setup.harness.runtime
        runtime.claudeExecutable = nil

        let session = try #require(try await runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Dev 1", task: "Add a world line to the README").first)
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .idle }

        let agent = session.agent
        #expect(agent.worktreePath == setup.project.path + "/.crew/dev-1")
        #expect(FileManager.default.fileExists(atPath: setup.stateDirectory(agent) + "/pid"))
        #expect(kinds(session).suffix(4) == ["assistant", "tool:Edit", "assistant", "other"], "\(kinds(session))")
        let launch = try #require(setup.harness.launches().last)
        #expect(launch.contains("Write(/\(agent.worktreePath!)/**)"))
        #expect(setup.harness.launchEnvironments().last == "key= token=")

        session.send("Now add a second line")
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .idle && setup.harness.launches().count == 2 }
        #expect(setup.harness.launches().last?.contains("--resume \(agent.sessionId!)") == true)
    }

    @Test func stoppingKillsTheProcessOnTheHost() async throws {
        let setup = try await Setup.make(mode: "slow")
        defer { setup.cleanUp() }
        let session = try #require(try await setup.harness.runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Dev 1", task: "Take your time").first)
        try await waitUntil(timeout: .seconds(20)) { session.transcript.activeTool != nil }
        let pidText = try String(contentsOfFile: setup.stateDirectory(session.agent) + "/pid", encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)

        session.stop()
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .stopped }
        try await waitUntil(timeout: .seconds(10)) { kill(pid, 0) != 0 }
    }

    @Test func recreatesAMissingWorktreeOnTheHostBeforeTheNextTurn() async throws {
        let setup = try await Setup.make()
        defer { setup.cleanUp() }
        let session = try #require(try await setup.harness.runtime.spawn(in: setup.project, kind: .builder, count: 1, git: setup.harness.repo.git, name: "Dev 1", task: "Add a world line to the README").first)
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .idle }
        let worktree = try #require(session.agent.worktreeURL)
        try FileManager.default.removeItem(at: worktree)
        _ = try await setup.harness.repo.git.run(["worktree", "prune"], in: setup.harness.repo.root)

        session.send("Keep going")
        try await waitUntil(timeout: .seconds(20)) { session.agent.status == .idle && setup.harness.launches().count == 2 }
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(kinds(session).contains("notice:restoringWorktree"))
    }

    private func kinds(_ session: AgentSession) -> [String] {
        session.transcript.entries.map { entry in
            switch entry.content {
            case .user: "user"
            case .assistant: "assistant"
            case .tool(let tool): "tool:\(tool.name)"
            case .notice(let notice, _): "notice:\(notice.rawValue)"
            default: "other"
            }
        }
    }
}
