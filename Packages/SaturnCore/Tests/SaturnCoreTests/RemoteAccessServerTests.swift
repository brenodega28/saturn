import Foundation
import NIOWebSocket
import Testing
@testable import SaturnCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct RemoteAccessServerTests {
    static func startHost(data: URL) async throws -> SaturnHost {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolLocator().searchPath
        let options = HostOptions(
            processEnvironment: environment, stopGracePeriod: .seconds(2), livePublishInterval: .milliseconds(50),
            runsBackgroundLoops: false, providerMode: .claudeSignIn
        )
        return try await SaturnHost.start(paths: AppPaths(root: data), secrets: InMemorySecretStore(), options: options)
    }

    @Test func remoteAccessIsOffByDefaultAndNothingListens() async throws {
        let h = try await DaemonHarness.make()
        let status = try await h.host.perform(RemoteAccessCommands.Status())
        #expect(!status.enabled)
        #expect(status.port == 7878)
        #expect(status.addresses.isEmpty)
        #expect(!h.remote.isListening)
        #expect(h.host.settings.remoteAccess == nil)
        await h.cleanUp()

        let data = DaemonTestPaths.shortDirectory("ro")
        defer { try? FileManager.default.removeItem(at: data) }
        let port = RemoteTestNetwork.freePort()
        try DaemonFiles.saveSettings(DaemonSettings(remoteAccess: RemoteAccessSettings(enabled: false, port: port)), paths: AppPaths(root: data))
        let host = try await Self.startHost(data: data)
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.server?.remoteAccess.isListening == false)
        #expect(!RemoteTestNetwork.canConnect(port: port))
        #expect(try RemoteTestNetwork.listeningAddresses(port: port).isEmpty)
        await host.stop()
    }

    @Test func enabledFlagAndPortPersistAcrossRestarts() async throws {
        let data = DaemonTestPaths.shortDirectory("rp")
        defer { try? FileManager.default.removeItem(at: data) }
        var host = try await Self.startHost(data: data)
        let port = RemoteTestNetwork.freePort()
        let status = try await host.perform(RemoteAccessCommands.SetEnabled(enabled: true, port: port))
        #expect(status.enabled && status.port == port)
        #expect(DaemonFiles.loadSettings(paths: AppPaths(root: data))?.remoteAccess == RemoteAccessSettings(enabled: true, port: port))
        await host.stop()
        try await waitUntil { !RemoteTestNetwork.canConnect(port: port) }

        host = try await Self.startHost(data: data)
        try await waitUntil { host.server?.remoteAccess.isListening == true }
        #expect(host.server?.remoteAccess.port == port)
        let off = try await host.perform(RemoteAccessCommands.SetEnabled(enabled: false))
        #expect(!off.enabled)
        #expect(!RemoteTestNetwork.canConnect(port: port))
        #expect(try RemoteTestNetwork.listeningAddresses(port: port).isEmpty)
        #expect(DaemonFiles.loadSettings(paths: AppPaths(root: data))?.remoteAccess == RemoteAccessSettings(enabled: false, port: port))
        await host.stop()
    }

    @Test func listenerBindsOnlyToLoopbackAndTailscale() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        let status = try await h.host.perform(RemoteAccessCommands.Status())
        #expect(status.enabled)
        #expect(status.addresses.first == "127.0.0.1")
        #expect(status.addresses.allSatisfy(RemoteAccessAddresses.isAllowed))
        let listening = try RemoteTestNetwork.listeningAddresses(port: port)
        #expect(listening.contains("127.0.0.1"))
        #expect(!listening.isEmpty && listening.allSatisfy(RemoteAccessAddresses.isAllowed), "\(listening)")
        #expect(Set(listening) == Set(status.addresses))
        await h.cleanUp()
    }

    @Test func unsafeAddressesAreNeverBound() async throws {
        let directory = DaemonTestPaths.shortDirectory("ru")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = RemoteAccessServer(
            devicesFile: AppPaths(root: directory).remoteDevices, webRoot: nil,
            addresses: { ["0.0.0.0", "10.0.0.1", "192.168.1.20", "127.0.0.1"] }
        ) { channel, _ in channel.close() }
        try await server.start(port: 0)
        let port = try #require(server.port)
        #expect(server.addresses == ["127.0.0.1"])
        #expect(try RemoteTestNetwork.listeningAddresses(port: port) == ["127.0.0.1"])
        await server.stop()
        #expect(!RemoteTestNetwork.canConnect(port: port))
    }

    @Test func missingOrBadTokensAreClosedWith4401() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        for token in [nil, "", "not-a-token"] {
            let socket = h.remoteSocket(port: port, token: token)
            #expect(try await socket.closeCode() == .unknown(4401), "token \(token ?? "nil")")
        }
        let (token, _) = try h.pairedToken()
        let bearerless = RemoteTestSocket(url: "ws://127.0.0.1:\(port)/ws", headers: [.authorization: "Basic \(token)"])
        #expect(try await bearerless.closeCode() == .unknown(4401))
        let bearer = RemoteTestSocket(url: "ws://127.0.0.1:\(port)/ws", headers: [.authorization: "Bearer \(token)"])
        let messages = try await bearer.handshake()
        guard case .welcome = messages.first else { Issue.record("Expected welcome, got \(messages)"); return }
        bearer.close()
        #expect(try await bearer.closeCode() != .unknown(4401))
        await h.cleanUp()
    }

    @Test func revokingADeviceClosesItsLiveSocketsAndRejectsItsToken() async throws {
        let h = try await DaemonHarness.make()
        let port = try await h.enableRemoteAccess()
        let (token, device) = try h.pairedToken("Revoked phone")
        let (otherToken, _) = try h.pairedToken("Kept phone")
        let first = h.remoteSocket(port: port, token: token)
        let second = h.remoteSocket(port: port, token: token)
        let other = h.remoteSocket(port: port, token: otherToken)
        for socket in [first, second, other] { try await socket.handshake() }
        try await waitUntil { h.host.status().clients == 3 }

        try await h.host.perform(RemoteAccessCommands.Revoke(deviceID: device.id))
        #expect(try await first.closeCode() == .unknown(4401))
        #expect(try await second.closeCode() == .unknown(4401))
        try await waitUntil { h.host.status().clients == 1 }
        #expect(try await h.host.perform(RemoteAccessCommands.Status()).pairedDevices.map(\.name) == ["Kept phone"])

        let again = h.remoteSocket(port: port, token: token)
        #expect(try await again.closeCode() == .unknown(4401))
        let result = try await other.perform(SettingsCommands.Status())
        #expect(result.error == nil)
        await #expect(throws: CommandFailure.notFound("The device")) {
            try await h.host.perform(RemoteAccessCommands.Revoke(deviceID: device.id))
        }
        other.close()
        await h.cleanUp()
    }

    @Test func pairingOverHTTPIssuesATokenOnce() async throws {
        let h = try await DaemonHarness.make()
        await #expect(throws: CommandFailure.self) { try await h.host.perform(RemoteAccessCommands.BeginPairing()) }
        let port = try await h.enableRemoteAccess()
        let pairing = try await h.host.perform(RemoteAccessCommands.BeginPairing())
        #expect(pairing.code.count == 6)
        #expect(pairing.url.hasSuffix(":\(port)/#pair"))
        #expect(pairing.url.hasPrefix("http://"))
        let host = pairing.url.dropFirst("http://".count).split(separator: ":").first.map(String.init) ?? ""
        #expect(RemoteAccessAddresses.isAllowed(host))
        #expect(abs(pairing.expiresAt.timeIntervalSinceNow - 300) < 5)

        let wrong = try await RemoteTestHTTP.pair(port: port, code: pairing.code == "000000" ? "999999" : "000000")
        #expect(wrong.status == 401)
        let paired = try await RemoteTestHTTP.pair(port: port, code: pairing.code, name: "Test phone")
        #expect(paired.status == 200)
        let token = try #require(paired.body["token"])
        let deviceID = try #require(paired.body["deviceID"].flatMap { UUID(uuidString: $0) })
        let reused = try await RemoteTestHTTP.pair(port: port, code: pairing.code)
        #expect(reused.status == 401)

        let devices = try await h.host.perform(RemoteAccessCommands.Status()).pairedDevices
        #expect(devices.map(\.id) == [deviceID])
        #expect(devices.first?.name == "Test phone")
        let stored = try String(contentsOf: h.paths.remoteDevices, encoding: .utf8)
        #expect(!stored.contains(token))

        let socket = h.remoteSocket(port: port, token: token)
        let messages = try await socket.handshake()
        guard case .welcome = messages.first else { Issue.record("Expected welcome"); return }
        socket.close()
        await h.cleanUp()
    }

    @Test func pairingCodesExpireOverHTTP() async throws {
        let directory = DaemonTestPaths.shortDirectory("rx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let server = RemoteAccessServer(
            devicesFile: AppPaths(root: directory).remoteDevices, webRoot: nil, now: { clock.now }, addresses: { ["127.0.0.1"] }
        ) { channel, _ in channel.close() }
        try await server.start(port: 0)
        let port = try #require(server.port)
        let pairing = server.beginPairing()
        #expect(pairing.url == "http://127.0.0.1:\(port)/#pair")
        #expect(pairing.expiresAt == clock.now.addingTimeInterval(300))
        clock.advance(301)
        #expect(try await RemoteTestHTTP.pair(port: port, code: pairing.code).status == 401)
        #expect(server.devices.isEmpty)

        let fresh = server.beginPairing()
        clock.advance(120)
        #expect(try await RemoteTestHTTP.pair(port: port, code: fresh.code).status == 200)
        #expect(server.devices.count == 1)
        await server.stop()
    }

    @Test func servesThePlaceholderOrTheBuiltWebClient() async throws {
        let directory = DaemonTestPaths.shortDirectory("rw")
        defer { try? FileManager.default.removeItem(at: directory) }
        let placeholder = RemoteAccessServer(devicesFile: directory.appending(path: "a.json"), webRoot: directory.appending(path: "missing"), addresses: { [] }) { channel, _ in channel.close() }
        try await placeholder.start(port: 0)
        let page = try await RemoteTestHTTP.get(port: try #require(placeholder.port), path: "/")
        #expect(page.status == 200)
        #expect(page.body.contains("Web client not built"))
        await placeholder.stop()

        let dist = directory.appending(path: "dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dist.appending(path: "assets"), withIntermediateDirectories: true)
        try "<!doctype html><title>Saturn Remote</title>".write(to: dist.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "console.log('saturn')".write(to: dist.appending(path: "assets/app.js"), atomically: true, encoding: .utf8)
        let built = RemoteAccessServer(devicesFile: directory.appending(path: "b.json"), webRoot: dist, addresses: { [] }) { channel, _ in channel.close() }
        try await built.start(port: 0)
        let builtPort = try #require(built.port)
        #expect(try await RemoteTestHTTP.get(port: builtPort, path: "/").body.contains("<title>Saturn Remote</title>"))
        #expect(try await RemoteTestHTTP.get(port: builtPort, path: "/assets/app.js").body == "console.log('saturn')")
        #expect(try await RemoteTestHTTP.get(port: builtPort, path: "/nothing.js").status == 404)
        #expect(try await RemoteTestHTTP.pair(port: builtPort, code: "123456").status == 401)
        await built.stop()
    }

    @Test func bundledWebRootPointsAtRemoteDist() throws {
        let root = try #require(RemoteAccessServer.bundledWebRoot)
        #expect(root.path.hasSuffix("Remote/dist"))
        #expect(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path))
    }
}
