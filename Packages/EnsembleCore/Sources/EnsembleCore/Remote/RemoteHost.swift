import Foundation

public struct RemoteHostInfo: Sendable, Equatable {
    public let home: String
    public let system: String
    public let gitPath: String?
    public let claudePath: String?
    public let hasGitIdentity: Bool

    public init(home: String, system: String, gitPath: String?, claudePath: String?, hasGitIdentity: Bool = true) {
        self.home = home
        self.system = system
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.hasGitIdentity = hasGitIdentity
    }
}

public struct RemoteDirectory: Sendable, Equatable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let name: String
        public let isGitRepository: Bool

        public var id: String { name }

        public init(name: String, isGitRepository: Bool) {
            self.name = name
            self.isGitRepository = isGitRepository
        }
    }

    public let path: String
    public let entries: [Entry]

    public init(path: String, entries: [Entry]) {
        self.path = path
        self.entries = entries
    }
}

public enum RemoteFolderError: Error, LocalizedError, Equatable {
    case notFound(String)
    case notARepository(String)
    case gitMissing
    case unexpectedOutput

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "\(path) doesn’t exist on the host, or you can’t open it."
        case .notARepository(let path): "\(path) isn’t inside a git repository. Ensemble needs git to give each agent its own worktree."
        case .gitMissing: "git isn’t installed on the host, or it isn’t on the PATH of a non-interactive ssh session."
        case .unexpectedOutput: "The host sent back something Ensemble couldn’t read."
        }
    }
}

public protocol RemoteDirectoryListing: Sendable {
    func list(_ path: String) async throws -> RemoteDirectory
}

public struct RemoteHost: RemoteDirectoryListing {
    static let missingExitCode: Int32 = 3
    static let notARepositoryExitCode: Int32 = 128
    static let commandNotFoundExitCode: Int32 = 127

    static let expandPath = #"p=$1; case $p in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac; cd -- "$p" 2>/dev/null || exit 3"#

    static let listScript = expandPath + #"""
    ; printf '%s\0' "$(pwd)"
    for d in .[!.]* ..?* *; do
      [ -d "$d" ] || continue
      if [ -e "$d/.git" ]; then printf 'g%s\0' "$d"; else printf 'd%s\0' "$d"; fi
    done
    """#

    static let repositoryRootScript = expandPath + #"; command -v git >/dev/null 2>&1 || exit 127; git rev-parse --show-toplevel"#

    static let probeScript = #"""
    claude=$(command -v claude 2>/dev/null)
    for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
      [ -z "$claude" ] && [ -x "$c" ] && claude=$c
    done
    identity=no
    command -v git >/dev/null 2>&1 && git var GIT_COMMITTER_IDENT >/dev/null 2>&1 && identity=yes
    printf '%s\0' "$HOME" "$(uname -sm)" "$(command -v git 2>/dev/null)" "$claude" "$identity"
    """#

    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    public func probe() async throws -> RemoteHostInfo {
        let result = try await client.run(Self.shellScript(Self.probeScript))
        let fields = Self.records(result.standardOutput)
        guard fields.count == 5 else { throw RemoteFolderError.unexpectedOutput }
        return RemoteHostInfo(
            home: fields[0], system: fields[1],
            gitPath: fields[2].isEmpty ? nil : fields[2],
            claudePath: fields[3].isEmpty ? nil : fields[3],
            hasGitIdentity: fields[4] == "yes"
        )
    }

    public func list(_ path: String) async throws -> RemoteDirectory {
        let result = try await client.run(Self.shellScript(Self.listScript, path))
        if result.exitCode == Self.missingExitCode { throw RemoteFolderError.notFound(path) }
        return try Self.parseListing(result.standardOutput)
    }

    public func repositoryRoot(containing path: String) async throws -> String {
        let result = try await client.run(Self.shellScript(Self.repositoryRootScript, path))
        switch result.exitCode {
        case 0:
            let root = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard root.hasPrefix("/") else { throw RemoteFolderError.unexpectedOutput }
            return root
        case Self.missingExitCode: throw RemoteFolderError.notFound(path)
        case Self.commandNotFoundExitCode: throw RemoteFolderError.gitMissing
        default: throw RemoteFolderError.notARepository(path)
        }
    }

    public func currentBranch(in repository: String) async throws -> String? {
        let result = try await client.run(arguments: ["git", "symbolic-ref", "--short", "-q", "HEAD"], in: repository)
        let branch = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !branch.isEmpty ? branch : nil
    }

    static func shellScript(_ script: String, _ arguments: String...) -> String {
        ShellQuote.command(["sh", "-c", script, "ensemble"] + arguments)
    }

    static func records(_ output: String) -> [String] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        return fields
    }

    static func parseListing(_ output: String) throws -> RemoteDirectory {
        let fields = records(output)
        guard let path = fields.first, path.hasPrefix("/") else { throw RemoteFolderError.unexpectedOutput }
        let entries = fields.dropFirst().compactMap { field -> RemoteDirectory.Entry? in
            guard let kind = field.first, field.count > 1 else { return nil }
            return RemoteDirectory.Entry(name: String(field.dropFirst()), isGitRepository: kind == "g")
        }
        return RemoteDirectory(path: path, entries: entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}

public struct RemoteProjectUnsupported: Error, LocalizedError, Equatable {
    public let feature: String

    public init(_ feature: String) {
        self.feature = feature
    }

    public static func check(_ project: Project, _ feature: String) throws {
        if project.isRemote { throw RemoteProjectUnsupported(feature) }
    }

    public var errorDescription: String? {
        "\(feature) isn’t available for SSH projects yet."
    }
}
