import Darwin
import Foundation
import Observation

public enum AppRunState: Sendable, Equatable {
    case idle
    case starting
    case running(ports: [Int], since: Date)
    case stopped(exitCode: Int32?)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .starting, .running: true
        case .idle, .stopped, .failed: false
        }
    }

    public var ports: [Int] {
        if case .running(let ports, _) = self { return ports }
        return []
    }
}

@MainActor
@Observable
public final class AppRunner {
    public static let logSource = "run"
    public static let maximumLineLength = 2000
    public static let logLimit = 500

    public let projectId: Int64
    public private(set) var state: AppRunState = .idle
    public private(set) var branch: String?
    public private(set) var worktree: URL?
    public private(set) var command: String?
    public private(set) var label: String?
    public private(set) var startedAt: Date?
    public private(set) var processGroup: pid_t?
    public var environment: [String: String]
    public var killGracePeriod: Duration
    public var portWait: Duration
    public var remote: RemoteAppHost?
    public private(set) var forwardedPorts: [Int: Int] = [:]

    @ObservationIgnored private let log: ActivityLog
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var urlPorts: [Int] = []
    @ObservationIgnored private var announcedReady = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var openStreams = 0
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var forwards: [Int: SSHPortForward] = [:]
    @ObservationIgnored private var remotePidFile: String?
    @ObservationIgnored private var runningRemote: RemoteAppHost?

    public init(projectId: Int64, log: ActivityLog, environment: [String: String], killGracePeriod: Duration = .seconds(5), portWait: Duration = .seconds(30)) {
        self.projectId = projectId
        self.log = log
        log.sourceLimits[Self.logSource] = Self.logLimit
        self.environment = environment
        self.killGracePeriod = killGracePeriod
        self.portWait = portWait
    }

    public static func environment(from process: [String: String]) -> [String: String] {
        process.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDECODE"
        }
    }

    public var isActive: Bool { processGroup != nil }

    public func isRunning(in folder: URL) -> Bool {
        guard isActive, let worktree else { return false }
        return realPath(of: worktree) == realPath(of: folder)
    }

    public func start(command: String, label: String? = nil, in worktree: URL, branch: String, port: Int?) async {
        if processGroup != nil { await stop() }
        generation += 1
        let current = generation
        stopRequested = false
        urlPorts = []
        announcedReady = false
        self.command = command
        self.label = label ?? command
        self.branch = branch
        self.worktree = worktree
        startedAt = .now
        state = .starting
        append(.debug, "\(label ?? command) · \(branch)")

        var variables = remote == nil ? environment : [:]
        variables["ENSEMBLE_WORKTREE"] = worktree.path
        if let port {
            variables["PORT"] = String(port)
            variables["ENSEMBLE_PORT"] = String(port)
        }
        runningRemote = remote
        let launched: ProcessGroup.Launch
        do {
            if let remote {
                let pidFile = remote.stateDirectory(named: "apps/\(projectId).pid")
                remotePidFile = pidFile
                let assignments = variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                let remoteCommand = ShellQuote.command(["sh", "-c", ShellScript.remoteWrapper, ShellScript.remoteWrapper, worktree.path, pidFile, command] + assignments)
                launched = try ProcessGroup.spawn(
                    arguments: [remote.client.executable.path] + remote.client.arguments(for: remoteCommand),
                    environment: remote.client.runner.environment.map { "\($0.key)=\($0.value)" },
                    directory: FileManager.default.temporaryDirectory.path
                )
            } else {
                launched = try ProcessGroup.spawn(
                    arguments: [ShellScript.shell.path, "-lc", command],
                    environment: variables.map { "\($0.key)=\($0.value)" },
                    directory: worktree.path
                )
            }
        } catch {
            let message = "Couldn’t start \(label ?? command): \(error.localizedDescription)"
            state = .failed(message)
            append(.error, message)
            return
        }
        processGroup = launched.pid
        openStreams = 2
        consume(launched.output, isError: false, generation: current)
        consume(launched.error, isError: true, generation: current)
        watchExit(of: launched.pid, generation: current)
        watchPorts(of: launched.pid, generation: current)
    }

    public func stop() async {
        guard let group = processGroup else { return }
        stopRequested = true
        let grace = killGracePeriod
        if let remote = runningRemote, let pidFile = remotePidFile {
            await Self.signal(remote, pidFile: pidFile, "TERM")
            let deadline = ContinuousClock.now + grace
            while processGroup == group, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if processGroup == group { await Self.signal(remote, pidFile: pidFile, "KILL") }
        }
        await Task.detached { ProcessGroup.terminate(group, grace: grace) }.value
        await exitTask?.value
    }

    public func stopImmediately() {
        guard let group = processGroup else { return }
        stopRequested = true
        monitor?.cancel()
        if let remote = runningRemote, let pidFile = remotePidFile {
            Self.signalAndWait(remote, pidFile: pidFile, "KILL")
        }
        closeForwards()
        ProcessGroup.terminate(group, grace: killGracePeriod)
        processGroup = nil
        generation += 1
        state = .stopped(exitCode: nil)
        append(.warning, "stopped")
    }

    private func consume(_ stream: AsyncStream<[String]>, isError: Bool, generation current: Int) {
        Task { [weak self] in
            for await lines in stream {
                self?.receive(lines, isError: isError, generation: current)
            }
            self?.streamClosed(generation: current)
        }
    }

    private func streamClosed(generation current: Int) {
        guard current == generation else { return }
        openStreams -= 1
    }

    private func receive(_ lines: [String], isError: Bool, generation current: Int) {
        guard current == generation else { return }
        var entries: [LogEntry] = []
        for raw in lines {
            let line = ServerOutput.clean(raw)
            guard !line.isEmpty else { continue }
            if let port = ServerOutput.localPort(in: line), !urlPorts.contains(port) {
                urlPorts.append(port)
            }
            let message = line.count > Self.maximumLineLength ? String(line.prefix(Self.maximumLineLength)) + "…" : line
            let level: LogEntry.Level = isError && ServerOutput.looksLikeError(line) ? .error : .info
            entries.append(entry(level, message))
        }
        log.append(entries)
        if !urlPorts.isEmpty, case .starting = state {
            Task { [weak self] in await self?.checkPorts(generation: current) }
        }
    }

    private func watchExit(of pid: pid_t, generation current: Int) {
        let grace = killGracePeriod
        exitTask = Task { [weak self] in
            let status = await ProcessGroup.waitForExit(pid)
            await Task.detached { ProcessGroup.terminate(pid, grace: grace) }.value
            await self?.drainStreams(generation: current)
            self?.finish(status: status, generation: current)
        }
    }

    private func drainStreams(generation current: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while current == generation, openStreams > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func finish(status: Int32, generation current: Int) {
        guard current == generation else { return }
        monitor?.cancel()
        monitor = nil
        closeForwards()
        processGroup = nil
        generation += 1
        if stopRequested {
            state = .stopped(exitCode: nil)
            append(.warning, "stopped")
        } else {
            let code = ProcessGroup.exitCode(status)
            state = .stopped(exitCode: code)
            append(code == 0 ? .warning : .error, "exited with code \(code)")
        }
    }

    private func watchPorts(of group: pid_t, generation current: Int) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPorts(generation: current)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func checkPorts(generation current: Int) async {
        guard current == generation, let group = processGroup else { return }
        var ports: [Int] = []
        if let remote = runningRemote, let pidFile = remotePidFile {
            ports = await forwardedListeningPorts(on: remote, pidFile: pidFile, generation: current)
        } else {
            if let worktree, !FileManager.default.fileExists(atPath: worktree.path) {
                await stop()
                return
            }
            let socketPorts = await Task.detached { ListeningPorts.ports(inGroup: group) }.value
            for port in urlPorts + socketPorts where !ports.contains(port) {
                if await PortProbe.isListening(port: port) { ports.append(port) }
            }
        }
        guard current == generation, processGroup == group else { return }
        let since = startedAt ?? .now
        switch state {
        case .starting:
            if !ports.isEmpty {
                state = .running(ports: ports, since: since)
            } else if Date.now.timeIntervalSince(since) >= Double(portWait.components.seconds) {
                state = .running(ports: [], since: since)
            }
        case .running(let known, let since):
            if !ports.isEmpty, ports != known { state = .running(ports: ports, since: since) }
        default:
            break
        }
        if !announcedReady, let first = state.ports.first {
            announcedReady = true
            append(.info, "ready · http://localhost:\(first) · \(branch ?? "")")
        }
    }

    static let remoteListeningScript = #"""
    pg=$(cat -- "$1" 2>/dev/null) || exit 0; shift
    [ -n "$pg" ] || exit 0
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -a -g "$pg" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p'
    fi
    for p in "$@"; do
      command -v nc >/dev/null 2>&1 && nc -z -w 1 127.0.0.1 "$p" >/dev/null 2>&1 && echo "$p"
    done
    exit 0
    """#

    private func forwardedListeningPorts(on remote: RemoteAppHost, pidFile: String, generation current: Int) async -> [Int] {
        let candidates = urlPorts.map(String.init)
        guard let result = try? await remote.client.run(arguments: ["sh", "-c", Self.remoteListeningScript, "ensemble", pidFile] + candidates) else { return [] }
        var remotePorts: [Int] = []
        for line in result.standardOutput.split(separator: "\n") {
            if let port = Int(line.trimmingCharacters(in: .whitespaces)), !remotePorts.contains(port) { remotePorts.append(port) }
        }
        var local: [Int] = []
        for port in remotePorts {
            guard current == generation else { return [] }
            let forward = forwards[port] ?? SSHPortForward(client: remote.client, remotePort: port)
            forwards[port] = forward
            do {
                let localPort = try await forward.open()
                forwardedPorts[port] = localPort
                local.append(localPort)
            } catch {
                forwards[port] = nil
                append(.warning, "Couldn’t forward port \(port) from the host: \(error.localizedDescription)")
            }
        }
        return local
    }

    private func closeForwards() {
        for forward in forwards.values { forward.stop() }
        forwards = [:]
        forwardedPorts = [:]
    }

    private static func signal(_ remote: RemoteAppHost, pidFile: String, _ name: String) async {
        _ = try? await remote.client.run(arguments: ["sh", "-c", RemoteAppHost.killScript(signal: name), "ensemble", pidFile])
    }

    private static func signalAndWait(_ remote: RemoteAppHost, pidFile: String, _ name: String) {
        let process = Process()
        process.executableURL = remote.client.executable
        process.arguments = remote.client.arguments(for: ShellQuote.command(["sh", "-c", RemoteAppHost.killScript(signal: name), "ensemble", pidFile]))
        process.environment = remote.client.runner.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date.now.addingTimeInterval(3)
        while process.isRunning, Date.now < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
    }

    private func append(_ level: LogEntry.Level, _ message: String) {
        log.append([entry(level, message)])
    }

    private func entry(_ level: LogEntry.Level, _ message: String) -> LogEntry {
        LogEntry(date: .now, level: level, source: Self.logSource, projectId: projectId, message: message)
    }
}

enum ProcessGroup {
    struct Launch {
        let pid: pid_t
        let output: AsyncStream<[String]>
        let error: AsyncStream<[String]>
    }

    static func spawn(arguments: [String], environment: [String], directory: String) throws -> Launch {
        let output = try pipe()
        let error: (read: Int32, write: Int32)
        do {
            error = try pipe()
        } catch {
            close(output.read)
            close(output.write)
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.write, 1)
        posix_spawn_file_actions_adddup2(&actions, error.write, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        close(output.write)
        close(error.write)
        guard result == 0 else {
            close(output.read)
            close(error.read)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        return Launch(pid: pid, output: lines(from: output.read), error: lines(from: error.read))
    }

    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    static func isAlive(_ group: pid_t) -> Bool {
        kill(-group, 0) == 0 || errno == EPERM
    }

    static func terminate(_ group: pid_t, grace: Duration) {
        guard group > 0, isAlive(group) else { return }
        kill(-group, SIGTERM)
        if waitForDeath(of: group, within: grace) { return }
        kill(-group, SIGKILL)
        _ = waitForDeath(of: group, within: .seconds(2))
    }

    static func waitForDeath(of group: pid_t, within limit: Duration) -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if !isAlive(group) { return true }
            usleep(20_000)
        }
        return !isAlive(group)
    }

    static func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }

    private static func pipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        return (descriptors[0], descriptors[1])
    }

    static func lines(from descriptor: Int32) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let reader = Thread {
                var pending: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    var lines: [String] = []
                    var start = 0
                    for index in pending.indices where pending[index] == 10 || pending[index] == 13 {
                        if index > start { lines.append(String(decoding: pending[start..<index], as: UTF8.self)) }
                        start = index + 1
                    }
                    pending.removeFirst(start)
                    if pending.count > 65_536 {
                        lines.append(String(decoding: pending, as: UTF8.self))
                        pending.removeAll()
                    }
                    if !lines.isEmpty { continuation.yield(lines) }
                }
                if !pending.isEmpty { continuation.yield([String(decoding: pending, as: UTF8.self)]) }
                close(descriptor)
                continuation.finish()
            }
            reader.start()
        }
    }
}
