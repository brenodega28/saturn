import Foundation

public struct GitClient: Sendable {
    public let executable: URL
    private let runner: CommandRunner

    public init(executable: URL, runner: CommandRunner) {
        self.executable = executable
        self.runner = runner
    }

    @discardableResult
    public func run(_ arguments: [String], in directory: URL) async throws -> String {
        try await runner.runChecked(executable, arguments, in: directory).standardOutput
    }

    public func version() async throws -> String {
        let output = try await runner.runChecked(executable, ["--version"]).standardOutput
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
        let result = try await runner.run(executable, ["symbolic-ref", "--short", "-q", "HEAD"], in: repository)
        let branch = result.standardOutput.trimmed
        return result.succeeded && !branch.isEmpty ? branch : nil
    }

    public func hasCommit(_ ref: String, in repository: URL) async throws -> Bool {
        try await runner.run(executable, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repository).succeeded
    }

    public func clone(_ remote: String, to destination: URL) async throws {
        try await run(["clone", "--", remote, destination.path], in: destination.deletingLastPathComponent())
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
