import Foundation
import Testing
@testable import EnsembleCore

struct RemoteDaemonInstallerTests {
    let installer = RemoteDaemonInstaller(client: SSHClient(destination: "me@server"), helperDirectory: DaemonTestPaths.ensembledExecutable.deletingLastPathComponent())

    func state(_ version: DaemonVersion?, hash: String? = nil, loaded: Bool = true) -> RemoteDaemonState {
        RemoteDaemonState(uid: 501, home: "/Users/me", architecture: "arm64", hasGUISession: true, installed: version, binaryHash: hash, isLoaded: loaded, isListening: loaded)
    }

    @Test func parsesTheProbeOutput() throws {
        let output = """
            uid=501
            home=/Users/me
            arch=arm64
            gui=1
            loaded=0
            version={"buildVersion":"1.0.0","protocolVersion":"1"}
            hash=abc
            sock=0
            filevault=FileVault is On.
            """
        let parsed = try #require(RemoteDaemonState.parse(output))
        #expect(parsed.uid == 501)
        #expect(parsed.hasGUISession)
        #expect(!parsed.isLoaded)
        #expect(parsed.installed == DaemonVersion(protocolVersion: 1, buildVersion: "1.0.0"))
        #expect(parsed.binaryHash == "abc")
        #expect(parsed.fileVaultOn == true)
        #expect(RemoteDaemonState.parse("uid=501\nhome=/Users/me\narch=arm64\ngui=0\n")?.hasGUISession == false)
    }

    @Test func plansInstallUpgradeAndRefusesToDowngrade() throws {
        let hash = try #require(installer.localHash)
        let current = DaemonVersion.current
        #expect(installer.plan(for: state(nil)) == .install)
        #expect(installer.plan(for: state(current, hash: hash)) == .upToDate)
        #expect(installer.plan(for: state(current, hash: hash, loaded: false)) == .install)
        #expect(installer.plan(for: state(current, hash: "different")) == .upgrade)
        #expect(installer.plan(for: state(DaemonVersion(protocolVersion: current.protocolVersion - 1, buildVersion: "0.9"))) == .upgrade)
        #expect(installer.plan(for: state(DaemonVersion(protocolVersion: current.protocolVersion, buildVersion: "0.9.9"), hash: hash)) == .upgrade)
        #expect(installer.plan(for: state(DaemonVersion(protocolVersion: current.protocolVersion + 1, buildVersion: "9.0"))) == .daemonIsNewer)
        #expect(installer.plan(for: state(DaemonVersion(protocolVersion: current.protocolVersion, buildVersion: "99.0.0"))) == .daemonIsNewer)
    }

    @Test func theLaunchAgentRunsServeAtLoadAndRestartsOnCrash() throws {
        let plist = RemoteDaemonInstaller.launchAgentPlist(home: "/Users/me")
        let parsed = try #require(try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        #expect(parsed["Label"] as? String == "dev.monoliti.ensembled")
        #expect(parsed["ProgramArguments"] as? [String] == ["/Users/me/.ensemble/bin/ensembled", "serve"])
        #expect(parsed["RunAtLoad"] as? Bool == true)
        #expect((parsed["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    }

    @Test func noConsoleSessionFailsWithAClearMessage() {
        let message = RemoteDaemonInstallerError.noConsoleSession("server").localizedDescription
        #expect(message.contains("Log in at the server"))
        #expect(message.contains("automatic login"))
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENSEMBLE_REAL_DAEMON_HOST"] != nil))
struct RealRemoteDaemonTests {
    let destination = ProcessInfo.processInfo.environment["ENSEMBLE_REAL_DAEMON_HOST"] ?? ""
    var helpers: URL { DaemonTestPaths.ensembledExecutable.deletingLastPathComponent() }

    @Test func installsIntoTheGUIDomainAndServesAClientOverSSH() async throws {
        let installer = RemoteDaemonInstaller(client: SSHClient(destination: destination), helperDirectory: helpers)
        let state = try await installer.ensureInstalled()
        #expect(state.hasGUISession)
        #expect(state.isLoaded)
        #expect(state.isListening)
        #expect(state.installed == .current)
        #expect(state.binaryHash == installer.localHash)

        let client = DaemonClient(transport: RemoteDaemonInstaller.transport(destination: destination), replicasDirectory: DaemonTestPaths.shortDirectory("rr"))
        client.start()
        defer { client.stop() }
        try await client.waitUntilConnected(timeout: .seconds(60))
        let status = try await client.send(SettingsCommands.Status())
        #expect(status.dataDirectory.hasSuffix("Library/Application Support/Ensemble"))
        let environment = try await client.send(SettingsCommands.CheckEnvironment())
        #expect(environment.claudePath?.hasSuffix(".local/bin/claude") == true)
        #expect(environment.fileVaultOn == true)
        print("remote daemon pid \(status.pid), clients \(status.clients), claude: \(environment.providerProblem ?? "-")")
    }

    @Test func anOlderClientIsToldToUpdateEnsemble() async throws {
        let transport = RemoteDaemonInstaller.transport(destination: destination)
        let (channel, process) = try transport.open()
        defer { channel.close(); process?.terminate() }
        try channel.send(.hello(Hello(clientID: UUID(), protocolVersion: EnsembleProtocol.version - 1)))
        var refusal: Refusal?
        for await line in channel.lines {
            if case .refused(let refused) = try ProtocolMessage.decode(line) {
                refusal = refused
                break
            }
        }
        #expect(refusal?.code == .clientTooOld)
        #expect(refusal?.message.contains("Update Ensemble") == true)
    }

    @Test func aDifferentBuildIsUpgradedWithKickstart() async throws {
        let copy = DaemonTestPaths.shortDirectory("up")
        defer { try? FileManager.default.removeItem(at: copy) }
        for file in RemoteDaemonInstaller.helperFiles {
            try FileManager.default.copyItem(at: helpers.appending(path: file), to: copy.appending(path: file))
        }
        let resign = Process()
        resign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        resign.arguments = ["--force", "--sign", "-", "--identifier", "dev.monoliti.ensembled.upgrade-test", copy.appending(path: "ensembled").path]
        try resign.run()
        resign.waitUntilExit()

        let client = SSHClient(destination: destination)
        let before = try await client.run("pgrep -f '.ensemble/bin/ensembled serve' | head -1").standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let upgrader = RemoteDaemonInstaller(client: client, helperDirectory: copy)
        let state = try await upgrader.probe()
        #expect(upgrader.plan(for: state) == .upgrade)
        await #expect(throws: RemoteDaemonInstallerError.runsActive(1)) {
            try await upgrader.ensureInstalled(activeRuns: 1)
        }
        let upgraded = try await upgrader.ensureInstalled(activeRuns: 1, confirmedRestart: true)
        #expect(upgraded.binaryHash == upgrader.localHash)
        #expect(upgraded.isListening)
        let after = try await client.run("pgrep -f '.ensemble/bin/ensembled serve' | head -1").standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!after.isEmpty && after != before)

        let restored = try await RemoteDaemonInstaller(client: client, helperDirectory: helpers).ensureInstalled(activeRuns: 0)
        #expect(restored.binaryHash == RemoteDaemonInstaller(client: client, helperDirectory: helpers).localHash)
    }
}
