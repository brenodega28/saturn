import Darwin
import SaturnCore
import Foundation
import ServiceManagement

enum LocalDaemonError: LocalizedError {
    case helperMissing(URL)
    case didNotStart(String)
    case unknownIdentity(URL)

    var errorDescription: String? {
        switch self {
        case .helperMissing(let url): "The Saturn daemon is missing from the app at \(url.path). Reinstall Saturn."
        case .didNotStart(let detail): "The Saturn daemon didn’t start. \(detail)"
        case .unknownIdentity(let url): "The Saturn daemon didn’t write its identity to \(url.path)."
        }
    }
}

@MainActor
enum LocalDaemon {
    static let label = "dev.monoliti.saturnd"
    static let plistName = "dev.monoliti.saturnd.plist"
    static let dataDirectoryVariable = "SATURN_DAEMON_DATA_DIR"

    static var defaultPaths: AppPaths {
        AppPaths(root: URL.applicationSupportDirectory.appending(path: "Saturn", directoryHint: .isDirectory))
    }

    static var paths: AppPaths {
        if let custom = ProcessInfo.processInfo.environment[dataDirectoryVariable], !custom.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        return defaultPaths
    }

    static var usesLaunchAgent: Bool {
        paths.root.standardizedFileURL == defaultPaths.root.standardizedFileURL
    }

    static var helper: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/saturnd")
    }

    static func isListening(_ paths: AppPaths) -> Bool {
        guard let socket = try? UnixSocket.connect(path: paths.daemonSocket.path) else { return false }
        close(socket)
        return true
    }

    static func connect(clientPaths: AppPaths) async throws -> DaemonConnection {
        let paths = paths
        if !isListening(paths) {
            try await start(paths)
        }
        guard let data = try? Data(contentsOf: paths.daemonIdentity),
              let identity = try? JSONDecoder().decode(DaemonIdentity.self, from: data) else {
            throw LocalDaemonError.unknownIdentity(paths.daemonIdentity)
        }
        let client = DaemonClient(
            clientID: clientID(clientPaths), transport: .socket(paths.daemonSocket),
            replicasDirectory: clientPaths.replicasDirectory, knownDaemon: identity
        )
        guard let replica = client.replica else { throw LocalDaemonError.unknownIdentity(paths.daemonIdentity) }
        let connection = DaemonConnection(client: client, replica: replica)
        connection.start()
        if replica.seq == nil {
            try await client.waitUntilConnected(timeout: .seconds(120))
        }
        return connection
    }

    static func clientID(_ clientPaths: AppPaths) -> UUID {
        let key = "daemon.clientID.\(clientPaths.root.path)"
        if let stored = AppDefaults.store.string(forKey: key).flatMap(UUID.init(uuidString:)) { return stored }
        let id = UUID()
        AppDefaults.store.set(id.uuidString, forKey: key)
        return id
    }

    static func start(_ paths: AppPaths) async throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw LocalDaemonError.helperMissing(helper) }
        if usesLaunchAgent, registerLaunchAgent() {
            if try await waitUntilListening(paths, timeout: .seconds(5)) { return }
            kickstart()
            if try await waitUntilListening(paths, timeout: .seconds(10)) { return }
        }
        try spawn(paths)
        guard try await waitUntilListening(paths, timeout: .seconds(30)) else {
            let log = (try? String(contentsOf: paths.daemonLog, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
            throw LocalDaemonError.didNotStart(log)
        }
    }

    static var launchAgent: SMAppService { SMAppService.agent(plistName: plistName) }

    static func registerLaunchAgent() -> Bool {
        let service = launchAgent
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return false
        case .notRegistered, .notFound:
            do {
                try service.register()
                return service.status == .enabled
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    static func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func spawn(_ paths: AppPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.daemonLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: paths.daemonLog)
        try log.seekToEnd()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["serve", "--data-dir", paths.root.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }

    static func waitUntilListening(_ paths: AppPaths, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isListening(paths), FileManager.default.fileExists(atPath: paths.daemonIdentity.path) { return true }
            try await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    static func stop(_ connection: DaemonConnection) async throws {
        try await connection.send(SettingsCommands.Shutdown())
    }
}
