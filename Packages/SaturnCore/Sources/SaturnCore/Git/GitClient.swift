import Foundation

public struct GitClient: Sendable {
    public typealias Executor = @Sendable ([String], String?) async throws -> CommandResult

    enum Transport: Sendable {
        case local(executable: URL, runner: CommandRunner)
        case ssh(SSHClient)
        case executor(Executor, any ProjectFileSystem)
    }

    let transport: Transport

    public init(executable: URL, runner: CommandRunner) {
        transport = .local(executable: executable, runner: runner)
    }

    public init(ssh client: SSHClient) {
        transport = .ssh(client)
    }

    public init(executor: @escaping Executor, fileSystem: any ProjectFileSystem) {
        transport = .executor(executor, fileSystem)
    }

    public var isRemote: Bool { sshClient != nil }

    public var fileSystem: any ProjectFileSystem {
        if case .executor(_, let fileSystem) = transport { return fileSystem }
        return sshClient.map { SSHFileSystem(client: $0) } ?? LocalFileSystem()
    }

    public var sshClient: SSHClient? {
        if case .ssh(let client) = transport { return client }
        return nil
    }

    public func execute(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        switch transport {
        case .local(let executable, let runner):
            return try await runner.run(executable, arguments, in: directory)
        case .ssh(let client):
            return try await client.run(arguments: ["git"] + arguments, in: directory?.path)
        case .executor(let executor, _):
            return try await executor(arguments, directory?.path)
        }
    }

    @discardableResult
    public func run(_ arguments: [String], in directory: URL) async throws -> String {
        try await checked(arguments, in: directory).standardOutput
    }

    public func version() async throws -> String {
        let output = try await checked(["--version"], in: nil).standardOutput
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "git version ", with: "")
    }

    public func repositoryRoot(containing directory: URL) async throws -> URL {
        let output = try await run(["rev-parse", "--show-toplevel"], in: directory)
        return URL(fileURLWithPath: output.trimmed, isDirectory: true)
    }

    public func commonDirectory(of repository: URL) async throws -> URL {
        let output = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repository)
        return URL(fileURLWithPath: output.trimmed, isDirectory: true)
    }

    public func currentBranch(in repository: URL) async throws -> String? {
        let result = try await execute(["symbolic-ref", "--short", "-q", "HEAD"], in: repository)
        let branch = result.standardOutput.trimmed
        return result.succeeded && !branch.isEmpty ? branch : nil
    }

    public func hasCommit(_ ref: String, in repository: URL) async throws -> Bool {
        try await execute(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repository).succeeded
    }

    public func clone(_ remote: String, to destination: URL) async throws {
        try await run(["clone", "--", remote, destination.path], in: destination.deletingLastPathComponent())
    }

    private func checked(_ arguments: [String], in directory: URL?) async throws -> CommandResult {
        let result = try await execute(arguments, in: directory)
        guard result.succeeded else {
            throw CommandError(command: (["git"] + arguments).joined(separator: " "), result: result)
        }
        return result
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
