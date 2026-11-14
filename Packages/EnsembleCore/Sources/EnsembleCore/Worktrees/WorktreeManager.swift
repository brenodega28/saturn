import Foundation

public enum WorktreeError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(agent: String)
    case notFound(agent: String)
    case outsideCrewDirectory(URL)
    case noCommits
    case branchMissing(String)

    public var errorDescription: String? {
        switch self {
        case .branchMissing(let branch): "The branch \(branch) no longer exists."
        case .invalidName(let name): "“\(name)” can’t be used as a worktree name."
        case .alreadyExists(let agent): "A worktree for \(agent) already exists."
        case .notFound(let agent): "No worktree found for \(agent)."
        case .outsideCrewDirectory(let url): "\(url.path) is not inside \(WorktreeManager.directoryName)/."
        case .noCommits: "The repository has no commits yet. Make a first commit before creating worktrees."
        }
    }
}

public struct WorktreeManager: Sendable {
    public static let directoryName = ".crew"
    public static let branchPrefix = ProjectPreferences.defaultBranchPrefix

    public let repository: URL
    public let branchPrefix: String
    private let git: GitClient
    private let fileSystem: any ProjectFileSystem

    public init(project: Project, git: GitClient) {
        self.init(repository: project.url, git: git, branchPrefix: ProjectPreferences.load(repository: project.filesRoot).branchPrefix)
    }

    public init(repository: URL, git: GitClient, fileSystem: (any ProjectFileSystem)? = nil, branchPrefix: String? = nil) {
        let fileSystem = fileSystem ?? git.sshClient.map { SSHFileSystem(client: $0) as any ProjectFileSystem } ?? LocalFileSystem()
        self.repository = fileSystem.isLocal ? repository.standardizedFileURL : URL(fileURLWithPath: fileSystem.canonicalPath(repository), isDirectory: true)
        self.git = git
        self.fileSystem = fileSystem
        self.branchPrefix = branchPrefix ?? (fileSystem.isLocal ? ProjectPreferences.load(repository: repository).branchPrefix : ProjectPreferences.defaultBranchPrefix)
    }

    public static func make(repository: URL, git: GitClient, fileSystem: any ProjectFileSystem) async -> WorktreeManager {
        let text = try? await fileSystem.readText(ProjectPreferences.file(in: repository))
        let prefix = text.flatMap { $0 }.map { ProjectPreferences.parse($0).branchPrefix }
        return WorktreeManager(repository: repository, git: git, fileSystem: fileSystem, branchPrefix: prefix)
    }

    public var crewDirectory: URL {
        repository.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    public func path(forAgent agent: String) throws -> URL {
        crewDirectory.appending(path: try validSlug(agent), directoryHint: .isDirectory)
    }

    public func branchName(agent: String, slug: String) throws -> String {
        "\(branchPrefix)/\(try validSlug(agent))/\(try validSlug(slug))"
    }

    @discardableResult
    public func create(agent: String, slug: String, from baseRef: String? = nil) async throws -> Worktree {
        let path = try path(forAgent: agent)
        let branch = try branchName(agent: agent, slug: slug)
        guard try await !fileSystem.fileExists(path) else {
            throw WorktreeError.alreadyExists(agent: path.lastPathComponent)
        }

        guard try await git.hasCommit(baseRef ?? "HEAD", in: repository) else {
            throw WorktreeError.noCommits
        }

        try await ensureExcluded()
        try await fileSystem.createDirectory(crewDirectory)
        try await git.run(["worktree", "add", "-b", branch, path.path] + (baseRef.map { [$0] } ?? []), in: repository)

        guard let worktree = try await list().first(where: { samePath($0.path, path) }) else {
            throw WorktreeError.notFound(agent: path.lastPathComponent)
        }
        return worktree
    }

    @discardableResult
    public func restore(at path: URL, branch: String) async throws -> Worktree {
        guard isInsideCrewDirectory(path) else { throw WorktreeError.outsideCrewDirectory(path) }
        guard try await !fileSystem.fileExists(path) else {
            throw WorktreeError.alreadyExists(agent: path.lastPathComponent)
        }
        guard try await git.hasCommit("refs/heads/\(branch)", in: repository) else {
            throw WorktreeError.branchMissing(branch)
        }
        try await ensureExcluded()
        try await git.run(["worktree", "prune"], in: repository)
        try await fileSystem.createDirectory(crewDirectory)
        try await git.run(["worktree", "add", path.path, branch], in: repository)
        guard let worktree = try await list().first(where: { samePath($0.path, path) }) else {
            throw WorktreeError.notFound(agent: path.lastPathComponent)
        }
        return worktree
    }

    public func list() async throws -> [Worktree] {
        try await allRegistered().filter { isInsideCrewDirectory($0.path) }
    }

    public func remove(_ worktree: Worktree, force: Bool, deleteBranch: Bool) async throws {
        guard isInsideCrewDirectory(worktree.path) else {
            throw WorktreeError.outsideCrewDirectory(worktree.path)
        }
        try await git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path.path], in: repository)
        if deleteBranch, let branch = worktree.branch {
            try await git.run(["branch", "-D", branch], in: repository)
        }
    }

    public func ensureExcluded() async throws {
        let excludeFile = try await git.commonDirectory(of: repository).appending(path: "info/exclude")
        let entry = "/\(Self.directoryName)/"
        let existing = (try await fileSystem.readText(excludeFile)) ?? ""
        let lines = existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(where: { [entry, "\(Self.directoryName)/", Self.directoryName, "/\(Self.directoryName)"].contains($0) }) else {
            return
        }
        try await fileSystem.createDirectory(excludeFile.deletingLastPathComponent())
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try await fileSystem.writeText(existing + separator + entry + "\n", to: excludeFile)
    }

    public func recover() async throws -> WorktreeRecovery {
        try await ensureExcluded()
        let pruned = try await list().filter(\.isPrunable)
        if !pruned.isEmpty {
            try await git.run(["worktree", "prune"], in: repository)
        }
        let worktrees = try await list()
        let registered = Set(worktrees.map { canonicalPath($0.path) })
        let orphaned = try await fileSystem.subdirectories(of: crewDirectory)
            .filter { !registered.contains(canonicalPath($0)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return WorktreeRecovery(worktrees: worktrees, pruned: pruned, orphanedDirectories: orphaned)
    }

    public func deleteOrphanedDirectory(_ directory: URL) async throws {
        guard isInsideCrewDirectory(directory), !samePath(directory, crewDirectory) else {
            throw WorktreeError.outsideCrewDirectory(directory)
        }
        try await fileSystem.removeItem(directory)
    }

    private func allRegistered() async throws -> [Worktree] {
        Worktree.parsePorcelain(try await git.run(["worktree", "list", "--porcelain"], in: repository))
    }

    private func validSlug(_ name: String) throws -> String {
        let slug = Slug.make(name)
        guard !slug.isEmpty else { throw WorktreeError.invalidName(name) }
        return slug
    }

    private func isInsideCrewDirectory(_ url: URL) -> Bool {
        canonicalPath(url).hasPrefix(canonicalPath(crewDirectory) + "/")
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func canonicalPath(_ url: URL) -> String {
        fileSystem.canonicalPath(url)
    }
}
