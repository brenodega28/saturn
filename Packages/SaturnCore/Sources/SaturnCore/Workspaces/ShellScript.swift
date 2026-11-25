import Darwin
import Foundation
import Synchronization

enum ShellScript {
    static let shell = URL(fileURLWithPath: "/bin/zsh")

    enum Outcome: Equatable {
        case exited(Int32)
        case timedOut
    }

    static func run(
        _ script: String, in directory: URL, environment: [String: String], log: URL, timeout: Duration, killGracePeriod: Duration
    ) async throws -> Outcome {
        let logDescriptor = open(log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard logDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(logDescriptor) }

        let pid = try spawn(
            arguments: [shell.path, "-lc", script],
            environment: environment.map { "\($0.key)=\($0.value)" },
            directory: directory.path,
            output: logDescriptor
        )

        let timedOut = Mutex(false)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            kill(-pid, SIGTERM)
            try await Task.sleep(for: killGracePeriod)
            kill(-pid, SIGKILL)
        }
        let status = await withTaskCancellationHandler {
            await waitForExit(pid)
        } onCancel: {
            kill(-pid, SIGKILL)
        }
        watchdog.cancel()

        if timedOut.withLock({ $0 }) {
            kill(-pid, SIGKILL)
            return .timedOut
        }
        let signal = status & 0x7f
        return .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }

    static let remoteWrapper = #"""
    if [ -z "$SATURN_SETSID" ] && command -v setsid >/dev/null 2>&1 && [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" != "$$" ]; then
      SATURN_SETSID=1; export SATURN_SETSID; exec setsid sh -c "$0" "$0" "$@"
    fi
    dir=$1; pidfile=$2; script=$3; shift 3
    umask 077
    mkdir -p -- "$(dirname -- "$pidfile")"
    while [ "$#" -gt 0 ]; do export "$1"; shift; done
    echo $$ > "$pidfile"
    cd -- "$dir" 2>/dev/null || { echo "Saturn: $dir doesn’t exist on the host." >&2; exit 127; }
    exec "${SHELL:-/bin/sh}" -lc "$script"
    """#


    static func tail(of log: URL, lines count: Int) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }

    private static func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }

    private static func spawn(arguments: [String], environment: [String], directory: String, output: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}
