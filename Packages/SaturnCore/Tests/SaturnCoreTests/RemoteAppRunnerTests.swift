import Darwin
import Foundation
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized) struct RemoteAppRunnerTests {
    let log = ActivityLog()

    func messages() -> [String] {
        log.entries.filter { $0.source == AppRunner.logSource }.map(\.message)
    }

    @Test func runsTheCommandOnTheHostStreamsItsOutputAndStopsIt() async throws {
        let host = try FakeSSHHost()
        defer { host.remove() }
        let worktree = host.home.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let client = SSHClient(destination: "devbox", executable: host.executable, runner: CommandRunner(environment: ["LEAKED": "mac"]), controlDirectory: nil)
        let runner = AppRunner(projectId: 7, log: log, environment: ["LEAKED": "mac"], killGracePeriod: .seconds(2))
        runner.remote = RemoteAppHost(client: client, home: host.home.path)

        await runner.start(command: "echo \"in $(basename \"$PWD\") port=$PORT leaked=${LEAKED:-none}\"; sleep 30", in: worktree, branch: "main", port: 4321)
        try await waitUntil { messages().contains("in repo port=4321 leaked=none") }
        let pid = try #require(Int32(try String(contentsOfFile: host.home.path + "/.cache/saturn/apps/7.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)
        #expect(runner.isActive)

        await runner.stop()
        #expect(runner.state == .stopped(exitCode: nil))
        try await waitUntil { kill(pid, 0) != 0 }
    }

    @Test func reportsTheExitCodeOfACommandThatEndsOnTheHost() async throws {
        let host = try FakeSSHHost()
        defer { host.remove() }
        let client = SSHClient(destination: "devbox", executable: host.executable, controlDirectory: nil)
        let runner = AppRunner(projectId: 8, log: log, environment: [:], killGracePeriod: .seconds(2))
        runner.remote = RemoteAppHost(client: client, home: host.home.path)

        await runner.start(command: "echo bye; exit 3", in: host.home, branch: "main", port: nil)
        try await waitUntil { if case .stopped = runner.state { true } else { false } }
        #expect(runner.state == .stopped(exitCode: 3))
        #expect(messages().contains("exited with code 3"))
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SATURN_REAL_SSH_HOST"] != nil))
struct RealRemoteAppRunnerTests {
    @Test func servesTheHostsAppOnThisMacThroughAForwardedPort() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["SATURN_REAL_SSH_HOST"])
        let client = SSHClient(destination: destination)
        let info = try await RemoteHost(client: client).probe()
        let folder = info.home + "/.cache/saturn/app-test"
        _ = try await client.runChecked(arguments: ["sh", "-c", #"mkdir -p "$1" && printf 'hello from the host\n' > "$1/index.html""#, "saturn", folder])
        let log = ActivityLog()
        let runner = AppRunner(projectId: 9, log: log, environment: [:], killGracePeriod: .seconds(3))
        runner.remote = RemoteAppHost(client: client, home: info.home)
        let port = Int.random(in: 41_000...48_000)

        await runner.start(command: "python3 -m http.server $PORT --bind 127.0.0.1", in: URL(fileURLWithPath: folder, isDirectory: true), branch: "main", port: port)
        try await waitUntil(timeout: .seconds(30)) { !runner.state.ports.isEmpty }
        let local = try #require(runner.state.ports.first)
        #expect(runner.forwardedPorts[port] == local)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(local)/index.html")!)
        #expect(String(decoding: data, as: UTF8.self) == "hello from the host\n")
        #expect(log.entries.contains { $0.message.hasPrefix("ready · http://localhost:\(local)") })

        await runner.stop()
        #expect(runner.forwardedPorts.isEmpty)
        let still = try await client.run(arguments: ["sh", "-c", "lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1 && echo up || echo down", "saturn", String(port)])
        #expect(still.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "down")
        #expect(!(await PortProbe.isListening(port: local)))
        _ = try? await client.run(arguments: ["rm", "-rf", "--", folder])
    }
}
