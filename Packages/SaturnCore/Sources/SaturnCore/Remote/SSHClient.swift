import Darwin
import Foundation
import Synchronization

public struct SSHError: Error, LocalizedError, Sendable, Equatable {
    public let destination: String
    public let message: String

    public var isHostKeyProblem: Bool {
        message.contains("Host key verification failed") || message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
    }

    public var errorDescription: String? {
        let host = SSHDestination.displayName(destination)
        if isHostKeyProblem {
            return "\(message)\n\nConnect once in Terminal with “ssh \(host)” to review and accept the host key, then try again."
        }
        if message.contains("Permission denied") {
            return "\(message)\n\nSaturn signs in with your SSH keys and agent only. Check that “ssh \(host)” works in Terminal without a password."
        }
        return message.isEmpty ? "Couldn’t connect to \(host)." : message
    }
}

public enum ShellQuote {
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(_ arguments: [String], in directory: String? = nil) -> String {
        let command = arguments.map(quote).joined(separator: " ")
        guard let directory else { return command }
        return "cd -- \(quote(directory)) && \(command)"
    }
}

public struct SSHClient: Sendable, Equatable {
    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/ssh")
    static let executableOverrides = Mutex<[String: URL]>([:])

    static func executable(for destination: String) -> URL? {
        executableOverrides.withLock { $0[destination] }
    }
    static let failureExitCode: Int32 = 255

    public let destination: String
    public let executable: URL
    public let controlDirectory: URL?
    let runner: CommandRunner

    public init(destination: String, executable: URL = SSHClient.defaultExecutable, runner: CommandRunner = CommandRunner(), controlDirectory: URL? = SSHClient.sharedControlDirectory()) {
        self.destination = destination
        self.executable = executable
        self.runner = runner
        self.controlDirectory = controlDirectory
    }

    public func arguments(for remoteCommand: String) -> [String] {
        var options = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "LogLevel=ERROR",
        ]
        if let controlDirectory {
            options += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlDirectory.path)/%C",
                "-o", "ControlPersist=300",
            ]
        }
        return options + ["--", destination, remoteCommand]
    }

    public func run(_ remoteCommand: String) async throws -> CommandResult {
        let result = try await runner.run(executable, arguments(for: remoteCommand))
        if result.exitCode == Self.failureExitCode {
            throw SSHError(destination: destination, message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    public func run(arguments: [String], in directory: String? = nil) async throws -> CommandResult {
        try await run(ShellQuote.command(arguments, in: directory))
    }

    public func runChecked(arguments: [String], in directory: String? = nil) async throws -> CommandResult {
        let result = try await run(arguments: arguments, in: directory)
        guard result.succeeded else {
            throw CommandError(command: arguments.joined(separator: " "), result: result)
        }
        return result
    }

    public static func sharedControlDirectory() -> URL? {
        let directory = URL(fileURLWithPath: "/tmp/saturn-ssh-\(getuid())", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard let attributes = try? manager.attributesOfItem(atPath: directory.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else { return nil }
        return directory
    }
}
