import Foundation
import Synchronization

public struct RemoteAppHost: Sendable, Equatable {
    static let settleTime: Duration = .milliseconds(2500)

    public let client: SSHClient
    public let home: String

    public init(client: SSHClient, home: String) {
        self.client = client
        self.home = home
    }

    public func stateDirectory(named name: String) -> String {
        "\(home)/.cache/ensemble/\(name)"
    }

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
            let deadline = ContinuousClock.now + RemoteAppHost.settleTime
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
