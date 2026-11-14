import Foundation
import Synchronization

public struct RemoteAgentHost: Sendable, Equatable {
    public let client: SSHClient
    public let claudePath: String
    public let home: String
    public let localPort: Int
    public let relayPort: Int

    public init(client: SSHClient, claudePath: String, home: String, localPort: Int, relayPort: Int) {
        self.client = client
        self.claudePath = claudePath
        self.home = home
        self.localPort = localPort
        self.relayPort = relayPort
    }

    public func relay(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.port == localPort else { return url }
        components.port = relayPort
        return components.url ?? url
    }

    public func stateDirectory(forAgent id: Int64) -> String {
        "\(home)/.cache/ensemble/agents/\(id)"
    }

    public func stateDirectory(named name: String) -> String {
        "\(home)/.cache/ensemble/\(name)"
    }
}

public struct RemoteAgentLaunch: Sendable, Equatable {
    public static let forwardedEnvironment = ["PORT", "ENSEMBLE_PORT"] + Array(AgentPermissions.artifactEnvironment.keys)

    public let host: RemoteAgentHost
    public let stateDirectory: String
    public let mcpConfiguration: String?
    public let apiKey: String?

    public init(host: RemoteAgentHost, stateDirectory: String, mcpConfiguration: String?, apiKey: String?) {
        self.host = host
        self.stateDirectory = stateDirectory
        self.mcpConfiguration = mcpConfiguration
        self.apiKey = apiKey
    }

    public var mcpConfigurationPath: String { stateDirectory + "/mcp.json" }
    public var pidFile: String { stateDirectory + "/pid" }

    public var preamble: [String] {
        [mcpConfiguration ?? "", apiKey ?? ""]
    }

    static let wrapper = #"""
    if [ -z "$ENSEMBLE_SETSID" ] && command -v setsid >/dev/null 2>&1 && [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" != "$$" ]; then
      ENSEMBLE_SETSID=1; export ENSEMBLE_SETSID; exec setsid sh -c "$0" "$0" "$@"
    fi
    wt=$1; program=$2; state=$3; shift 3
    umask 077
    mkdir -p -- "$state" || exit 3
    IFS= read -r mcp || exit 3
    IFS= read -r key || exit 3
    [ -n "$mcp" ] && printf '%s' "$mcp" > "$state/mcp.json"
    for v in $(env | sed -n 's/^\(ANTHROPIC_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    if [ -n "$key" ]; then ANTHROPIC_API_KEY=$key; export ANTHROPIC_API_KEY; fi
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do export "$1"; shift; done
    [ "$#" -gt 0 ] && shift
    echo $$ > "$state/pid"
    cd -- "$wt" 2>/dev/null || { echo "Ensemble: $wt doesn’t exist on the host." >&2; exit 3; }
    exec "$program" "$@"
    """#

    static func killScript(signal: String) -> String {
        """
        pid=$(cat -- "$1" 2>/dev/null) || exit 0
        [ -n "$pid" ] || exit 0
        if [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then kill -\(signal) -- "-$pid" 2>/dev/null; fi
        kill -\(signal) "$pid" 2>/dev/null
        rm -f -- "$1"
        exit 0
        """
    }

    func remoteCommand(directory: String, program: String, environment: [String: String], arguments: [String]) -> String {
        let assignments = Self.forwardedEnvironment.compactMap { key in environment[key].map { "\(key)=\($0)" } }
        return ShellQuote.command(["sh", "-c", Self.wrapper, Self.wrapper, directory, program, stateDirectory] + assignments + ["--"] + arguments)
    }

    func sshArguments(directory: String, environment: [String: String], arguments: [String]) -> [String] {
        host.client.arguments(for: remoteCommand(directory: directory, program: host.claudePath, environment: environment, arguments: arguments))
    }

    func signal(_ name: String) {
        let client = host.client
        let pidFile = pidFile
        Task.detached {
            _ = try? await client.run(arguments: ["sh", "-c", Self.killScript(signal: name), "ensemble", pidFile])
        }
    }
}

public enum RemoteTunnelError: Error, LocalizedError, Equatable {
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let message):
            "The host didn’t accept a reverse tunnel, which agents need to reach Ensemble’s tools and hooks (\(message)). "
                + "Enable AllowTcpForwarding in the host’s sshd_config. Some SSH proxies, such as OrbStack’s built-in one, don’t support it."
        }
    }
}

public final class RemoteTunnel: Sendable {
    static let settleTime: Duration = .milliseconds(2500)

    public let client: SSHClient
    public let localPort: Int
    private let state = Mutex<(process: Process?, remotePort: Int?)>((nil, nil))

    public init(client: SSHClient, localPort: Int) {
        self.client = client
        self.localPort = localPort
    }

    deinit {
        stop()
    }

    public var remotePort: Int? {
        state.withLock { $0.process?.isRunning == true ? $0.remotePort : nil }
    }

    public func open() async throws -> Int {
        if let port = remotePort { return port }
        var lastMessage = ""
        for port in [localPort] + (0..<6).map({ _ in Int.random(in: 20_000...60_000) }) {
            switch try await attempt(port) {
            case .success(let process):
                state.withLock { $0 = (process, port) }
                return port
            case .failure(let message):
                lastMessage = message
                guard message.contains("forwarding failed") else { throw SSHError(destination: client.destination, message: message) }
            }
        }
        throw RemoteTunnelError.refused(lastMessage)
    }

    public func stop() {
        let process = state.withLock { state -> Process? in
            defer { state = (nil, nil) }
            return state.process
        }
        if let process, process.isRunning { process.terminate() }
    }

    enum Attempt {
        case success(Process)
        case failure(String)
    }

    func attempt(_ remotePort: Int) async throws -> Attempt {
        let process = Process()
        process.executableURL = client.executable
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-R", "127.0.0.1:\(remotePort):127.0.0.1:\(localPort)",
            "--", client.destination,
        ]
        process.environment = client.runner.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let deadline = ContinuousClock.now + Self.settleTime
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.isRunning else {
            let data = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
            return .failure(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .success(process)
    }
}

public final class SSHPortForward: Sendable {
    public let client: SSHClient
    public let remotePort: Int
    private let state = Mutex<(process: Process?, localPort: Int?)>((nil, nil))

    public init(client: SSHClient, remotePort: Int) {
        self.client = client
        self.remotePort = remotePort
    }

    deinit {
        stop()
    }

    public var localPort: Int? {
        state.withLock { $0.process?.isRunning == true ? $0.localPort : nil }
    }

    public func open() async throws -> Int {
        if let port = localPort { return port }
        var candidates = [remotePort] + (0..<6).map { _ in Int.random(in: 20_000...60_000) }
        if await PortProbe.isListening(port: remotePort) { candidates.removeFirst() }
        var lastMessage = ""
        for port in candidates {
            let process = Process()
            process.executableURL = client.executable
            process.arguments = [
                "-N", "-T",
                "-o", "BatchMode=yes",
                "-o", "ControlPath=none",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ConnectTimeout=10",
                "-L", "127.0.0.1:\(port):127.0.0.1:\(remotePort)",
                "--", client.destination,
            ]
            process.environment = client.runner.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let deadline = ContinuousClock.now + RemoteTunnel.settleTime
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                state.withLock { $0 = (process, port) }
                return port
            }
            let data = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
            lastMessage = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard lastMessage.contains("forwarding failed") || lastMessage.contains("Address already in use") || lastMessage.contains("cannot listen") else {
                throw SSHError(destination: client.destination, message: lastMessage)
            }
        }
        throw SSHError(destination: client.destination, message: "Couldn’t forward the host’s port \(remotePort) to this Mac: \(lastMessage)")
    }

    public func stop() {
        let process = state.withLock { state -> Process? in
            defer { state = (nil, nil) }
            return state.process
        }
        if let process, process.isRunning { process.terminate() }
    }
}
