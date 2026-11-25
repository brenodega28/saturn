import Foundation
import GRDB
@testable import SaturnCore

final class TestBundleMarker {}

enum DaemonTestPaths {
    static func shortDirectory(_ prefix: String = "ed") -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var saturndExecutable: URL {
        Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "saturnd")
    }
}

@MainActor
struct DaemonHarness {
    let repo: TestRepository
    let bin: URL
    let data: URL
    let clientRoot: URL
    let host: SaturnHost

    var paths: AppPaths { AppPaths(root: data) }

    static func make(mode: String = "workflow", retention: Int = ChangeLog.defaultRetention) async throws -> DaemonHarness {
        let repo = try await TestRepository.make()
        let bin = try FakeClaude.install()
        try mode.write(to: bin.appending(path: "mode"), atomically: true, encoding: .utf8)
        let data = DaemonTestPaths.shortDirectory()
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_DIR"] = bin.path
        environment["PATH"] = ToolLocator().searchPath
        let options = HostOptions(
            claudeExecutable: bin.appending(path: "claude"),
            processEnvironment: environment,
            changeRetention: retention,
            stopGracePeriod: .seconds(2),
            pollInterval: .milliseconds(20),
            livePublishInterval: .milliseconds(50),
            runsBackgroundLoops: false,
            providerMode: .claudeSignIn
        )
        let host = try await SaturnHost.start(paths: AppPaths(root: data), secrets: InMemorySecretStore(), options: options)
        return DaemonHarness(repo: repo, bin: bin, data: data, clientRoot: DaemonTestPaths.shortDirectory("ec"), host: host)
    }

    func client(_ name: String = "a", knownDaemon: DaemonIdentity? = nil) -> DaemonClient {
        let client = DaemonClient(
            transport: .socket(paths.daemonSocket),
            replicasDirectory: clientRoot.appending(path: name, directoryHint: .isDirectory).appending(path: "replicas", directoryHint: .isDirectory),
            knownDaemon: knownDaemon
        )
        client.backoff = [.milliseconds(50)]
        return client
    }

    func connectedClient(_ name: String = "a") async throws -> DaemonClient {
        let client = client(name)
        client.start()
        try await client.waitUntilConnected()
        return client
    }

    func installWorkflows() async throws {
        try ProjectConfigLoader.installDefaults(repository: repo.root)
        try LegacyWorkflows.install(repository: repo.root)
        var feature = try ProjectConfigLoader.load(repository: repo.root).workflow("feature-delivery")!
        feature.end = WorkflowEnd(action: .merge, cleanUpWorktrees: true)
        try ProjectConfigLoader.write(feature, repository: repo.root)
        try await repo.git.run(["add", ".saturn"], in: repo.root)
        try await repo.git.run(["commit", "-m", "Add Saturn config"], in: repo.root)
    }

    func cleanUp() async {
        await host.stop()
        repo.delete()
        try? FileManager.default.removeItem(at: bin)
        try? FileManager.default.removeItem(at: data)
        try? FileManager.default.removeItem(at: clientRoot)
    }
}

extension DaemonClient {
    func read<T>(_ value: (Database) throws -> T) throws -> T? {
        try database?.writer.read(value)
    }
}
