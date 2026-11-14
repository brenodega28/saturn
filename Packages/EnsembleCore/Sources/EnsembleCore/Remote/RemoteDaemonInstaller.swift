import CryptoKit
import Foundation

public struct DaemonVersion: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var buildVersion: String

    public init(protocolVersion: Int, buildVersion: String) {
        self.protocolVersion = protocolVersion
        self.buildVersion = buildVersion
    }

    public static let current = DaemonVersion(protocolVersion: EnsembleProtocol.version, buildVersion: EnsembleProtocol.buildVersion)

    public static func parse(_ text: String) -> DaemonVersion? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let protocolVersion = object["protocolVersion"].flatMap(Int.init),
              let buildVersion = object["buildVersion"] else { return nil }
        return DaemonVersion(protocolVersion: protocolVersion, buildVersion: buildVersion)
    }

    public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }
}

public struct RemoteDaemonState: Sendable, Hashable {
    public var uid: Int
    public var home: String
    public var architecture: String
    public var hasGUISession: Bool
    public var installed: DaemonVersion?
    public var binaryHash: String?
    public var isLoaded: Bool
    public var isListening: Bool
    public var fileVaultOn: Bool?
    public var runningAgents: Int = 0

    public static func parse(_ output: String) -> RemoteDaemonState? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let uid = values["uid"].flatMap(Int.init), let home = values["home"] else { return nil }
        return RemoteDaemonState(
            uid: uid, home: home, architecture: values["arch"] ?? "",
            hasGUISession: values["gui"] == "1",
            installed: values["version"].flatMap(DaemonVersion.parse),
            binaryHash: values["hash"].flatMap { $0.isEmpty ? nil : $0 },
            isLoaded: values["loaded"] == "1",
            isListening: values["sock"] == "1",
            fileVaultOn: values["filevault"].map { $0.contains("FileVault is On") },
            runningAgents: values["agents"].flatMap(Int.init) ?? 0
        )
    }
}

public enum RemoteDaemonUpgrade: Equatable, Sendable {
    case upToDate
    case install
    case upgrade
    case daemonIsNewer
}

public enum RemoteDaemonInstallerError: Error, LocalizedError, Equatable {
    case noConsoleSession(String)
    case unsupportedArchitecture(String, String)
    case runsActive(Int)
    case didNotStart(String, String)
    case unreadableHost(String)
    case daemonIsNewer(String)

    public var errorDescription: String? {
        switch self {
        case .noConsoleSession(let host):
            "No one is logged in at \(host)’s screen, so there’s no session to run the Ensemble daemon in. Log in at the server (or through Screen Sharing), then try again. On a server without FileVault you can turn on automatic login in System Settings › Users & Groups so the daemon comes back after a restart."
        case .unsupportedArchitecture(let host, let architecture):
            "\(host) is a \(architecture) Mac. This build of the Ensemble daemon runs on Apple silicon (arm64) Macs only."
        case .runsActive(let count):
            "\(count) run\(count == 1 ? " is" : "s are") still going on this server. Upgrading restarts the daemon and interrupts \(count == 1 ? "it" : "them"); confirm to upgrade anyway."
        case .didNotStart(let host, let log):
            "The Ensemble daemon on \(host) didn’t start.\(log.isEmpty ? "" : "\n\n\(log)")"
        case .unreadableHost(let host):
            "Couldn’t read the state of \(host)."
        case .daemonIsNewer(let host):
            "\(host) runs a newer Ensemble daemon than this app. Update Ensemble on this Mac to use it."
        }
    }
}

public struct RemoteDaemonInstaller: Sendable {
    public static let label = "dev.monoliti.ensembled"
    public static let helperFiles = ["ensembled", "EnsembleCore_EnsembleCore.bundle"]
    public static let binDirectory = ".ensemble/bin"

    public let client: SSHClient
    public let helperDirectory: URL

    public init(client: SSHClient, helperDirectory: URL) {
        self.client = client
        self.helperDirectory = helperDirectory
    }

    var host: String { SSHDestination.displayName(client.destination) }

    public static func attachCommand(home: String? = nil) -> [String] {
        ["\(home ?? "~")/\(binDirectory)/ensembled", "attach"]
    }

    public static func transport(destination: String, executable: URL = SSHClient.defaultExecutable) -> DaemonTransport {
        let client = SSHClient(destination: destination, executable: executable, controlDirectory: nil)
        return .process(executable: executable, arguments: client.arguments(for: "~/\(binDirectory)/ensembled attach"))
    }

    static let probeScript = """
        uid=$(id -u)
        echo "uid=$uid"
        echo "home=$HOME"
        echo "arch=$(uname -m)"
        if launchctl print "gui/$uid" >/dev/null 2>&1; then echo gui=1; else echo gui=0; fi
        if launchctl print "gui/$uid/\(label)" >/dev/null 2>&1; then echo loaded=1; else echo loaded=0; fi
        bin="$HOME/\(binDirectory)/ensembled"
        if [ -x "$bin" ]; then
          echo "version=$("$bin" version 2>/dev/null)"
          echo "hash=$(shasum -a 256 "$bin" | cut -d' ' -f1)"
        fi
        if [ -S "$HOME/Library/Application Support/Ensemble/ensembled.sock" ]; then echo sock=1; else echo sock=0; fi
        echo "filevault=$(fdesetup status 2>/dev/null | head -1)"
        daemon=$(pgrep -f "$HOME/\(binDirectory)/ensembled serve" | head -1)
        if [ -n "$daemon" ]; then echo "agents=$(pgrep -P "$daemon" claude | wc -l | tr -d ' ')"; else echo agents=0; fi
        """

    public func probe() async throws -> RemoteDaemonState {
        let result = try await client.run(Self.probeScript)
        guard let state = RemoteDaemonState.parse(result.standardOutput) else { throw RemoteDaemonInstallerError.unreadableHost(host) }
        return state
    }

    public var localHash: String? {
        let url = helperDirectory.appending(path: "ensembled")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256Digest.hex(of: data)
    }

    public func plan(for state: RemoteDaemonState, local: DaemonVersion = .current) -> RemoteDaemonUpgrade {
        guard let installed = state.installed else { return .install }
        if installed.protocolVersion > local.protocolVersion { return .daemonIsNewer }
        if installed.protocolVersion < local.protocolVersion { return .upgrade }
        if DaemonVersion.isOlder(local.buildVersion, than: installed.buildVersion) { return .daemonIsNewer }
        if DaemonVersion.isOlder(installed.buildVersion, than: local.buildVersion) { return .upgrade }
        if let localHash, let remote = state.binaryHash, localHash != remote { return .upgrade }
        return state.isLoaded ? .upToDate : .install
    }

    public static func launchAgentPlist(home: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(home)/\(binDirectory)/ensembled</string>
        \t\t<string>serve</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        \t<key>ProcessType</key>
        \t<string>Standard</string>
        \t<key>ThrottleInterval</key>
        \t<integer>5</integer>
        \t<key>StandardErrorPath</key>
        \t<string>\(home)/.ensemble/ensembled.log</string>
        \t<key>StandardOutPath</key>
        \t<string>\(home)/.ensemble/ensembled.log</string>
        </dict>
        </plist>

        """
    }

    @discardableResult
    public func ensureInstalled(activeRuns: Int = 0, confirmedRestart: Bool = false) async throws -> RemoteDaemonState {
        let state = try await probe()
        guard state.hasGUISession else { throw RemoteDaemonInstallerError.noConsoleSession(host) }
        guard state.architecture == "arm64" else { throw RemoteDaemonInstallerError.unsupportedArchitecture(host, state.architecture) }
        switch plan(for: state) {
        case .upToDate:
            if !state.isListening { try await waitUntilListening(state) }
        case .daemonIsNewer:
            throw RemoteDaemonInstallerError.daemonIsNewer(host)
        case .install:
            try await upload()
            try await bootstrap(state)
            try await waitUntilListening(state)
        case .upgrade:
            let active = max(activeRuns, state.runningAgents)
            if active > 0, !confirmedRestart { throw RemoteDaemonInstallerError.runsActive(active) }
            try await upload()
            if state.isLoaded {
                _ = try await client.run("launchctl kickstart -k gui/\(state.uid)/\(Self.label)")
            } else {
                try await bootstrap(state)
            }
            try await waitUntilListening(state, requireRestart: state.isListening)
        }
        return try await probe()
    }

    func upload() async throws {
        let archive = try await Self.archive(helperDirectory)
        let script = """
            set -e
            rm -rf ~/.ensemble/bin.new ~/.ensemble/bin.old
            mkdir -p ~/.ensemble/bin.new
            tar -C ~/.ensemble/bin.new -xzf -
            if [ -d ~/\(Self.binDirectory) ]; then mv ~/\(Self.binDirectory) ~/.ensemble/bin.old; fi
            mv ~/.ensemble/bin.new ~/\(Self.binDirectory)
            rm -rf ~/.ensemble/bin.old
            ~/\(Self.binDirectory)/ensembled version
            """
        let result = try await StdinCommand.run(client.executable, client.arguments(for: script), input: archive)
        guard result.succeeded else { throw CommandError(command: "install ensembled on \(host)", result: result) }
    }

    func bootstrap(_ state: RemoteDaemonState) async throws {
        let plist = Self.launchAgentPlist(home: state.home)
        let script = """
            set -e
            mkdir -p ~/Library/LaunchAgents ~/.ensemble
            cat > ~/Library/LaunchAgents/\(Self.label).plist
            launchctl bootout gui/\(state.uid)/\(Self.label) >/dev/null 2>&1 || true
            launchctl bootstrap gui/\(state.uid) ~/Library/LaunchAgents/\(Self.label).plist
            """
        let result = try await StdinCommand.run(client.executable, client.arguments(for: script), input: Data(plist.utf8))
        guard result.succeeded else { throw CommandError(command: "launchctl bootstrap on \(host)", result: result) }
    }

    func waitUntilListening(_ state: RemoteDaemonState, requireRestart: Bool = false) async throws {
        let socket = "\(state.home)/Library/Application Support/Ensemble/ensembled.sock"
        let pause = requireRestart ? "sleep 1; " : ""
        let script = "\(pause)for i in $(seq 1 60); do [ -S \(ShellQuote.quote(socket)) ] && exit 0; sleep 0.5; done; exit 1"
        let result = try await client.run(script)
        guard result.succeeded else {
            let log = (try? await client.run("tail -n 20 ~/.ensemble/ensembled.log").standardOutput) ?? ""
            throw RemoteDaemonInstallerError.didNotStart(host, log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func stop(uid: Int) async throws {
        _ = try await client.run("launchctl bootout gui/\(uid)/\(Self.label) >/dev/null 2>&1 || true")
    }

    public func uninstall() async throws {
        let script = """
            launchctl bootout gui/$(id -u)/\(Self.label) >/dev/null 2>&1 || true
            rm -f ~/Library/LaunchAgents/\(Self.label).plist
            rm -rf ~/\(Self.binDirectory)
            """
        _ = try await client.run(script)
    }

    public func storeAPIKey(_ key: String, home: String, service: String = "dev.monoliti.Ensemble", account: String = SecretKey.anthropicAPIKey.rawValue) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\""), !trimmed.contains("\n") else {
            throw CommandFailure(code: .invalidArguments, message: "That doesn’t look like an API key.")
        }
        let line = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -T \"\(home)/\(Self.binDirectory)/ensembled\" -w \"\(trimmed)\"\n"
        let result = try await StdinCommand.run(client.executable, client.arguments(for: "security -i"), input: Data(line.utf8))
        guard result.succeeded, !result.standardError.contains("error") else {
            throw CommandError(command: "security add-generic-password on \(host)", result: result)
        }
    }

    public func deleteAPIKey(service: String = "dev.monoliti.Ensemble", account: String = SecretKey.anthropicAPIKey.rawValue) async throws {
        _ = try await client.run("security delete-generic-password -s \(ShellQuote.quote(service)) -a \(ShellQuote.quote(account)) >/dev/null 2>&1 || true")
    }

    static func archive(_ directory: URL) async throws -> Data {
        let result = try await StdinCommand.runData(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-C", directory.path, "-czf", "-"] + helperFiles, input: Data()
        )
        guard result.exitCode == 0 else {
            throw CommandError(command: "tar", result: CommandResult(exitCode: result.exitCode, standardOutput: "", standardError: result.error))
        }
        return result.output
    }
}

enum StdinCommand {
    struct DataResult {
        let exitCode: Int32
        let output: Data
        let error: String
    }

    static func run(_ executable: URL, _ arguments: [String], input: Data) async throws -> CommandResult {
        let result = try await runData(executable, arguments, input: input)
        return CommandResult(exitCode: result.exitCode, standardOutput: String(decoding: result.output, as: UTF8.self), standardError: result.error)
    }

    static func runData(_ executable: URL, _ arguments: [String], input: Data) async throws -> DataResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let writer = Thread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            writer.start()
            let errors = ErrorCollector(stderr.fileHandleForReading)
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return DataResult(exitCode: process.terminationStatus, output: output, error: errors.finish())
        }.value
    }
}

private final class ErrorCollector: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func finish() -> String {
        done.wait()
        return String(decoding: data, as: UTF8.self)
    }
}

enum SHA256Digest {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
