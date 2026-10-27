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

    public init(repository: URL, git: GitClient, branchPrefix: String? = nil) {
        self.repository = repository.standardizedFileURL
        self.git = git
        self.branchPrefix = branchPrefix ?? ProjectPreferences.load(repository: repository).branchPrefix
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
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw WorktreeError.alreadyExists(agent: path.lastPathComponent)
        }

        guard try await git.hasCommit(baseRef ?? "HEAD", in: repository) else {
            throw WorktreeError.noCommits
        }

        try await ensureExcluded()
        try FileManager.default.createDirectory(at: crewDirectory, withIntermediateDirectories: true)
        try await git.run(["worktree", "add", "-b", branch, path.path] + (baseRef.map { [$0] } ?? []), in: repository)

        guard let worktree = try await list().first(where: { Self.samePath($0.path, path) }) else {
            throw WorktreeError.notFound(agent: path.lastPathComponent)
        }
        return worktree
    }

    @discardableResult
    public func restore(at path: URL, branch: String) async throws -> Worktree {
        guard isInsideCrewDirectory(path) else { throw WorktreeError.outsideCrewDirectory(path) }
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw WorktreeError.alreadyExists(agent: path.lastPathComponent)
        }
        guard try await git.hasCommit("refs/heads/\(branch)", in: repository) else {
            throw WorktreeError.branchMissing(branch)
        }
        try await ensureExcluded()
        try await git.run(["worktree", "prune"], in: repository)
        try FileManager.default.createDirectory(at: crewDirectory, withIntermediateDirectories: true)
        try await git.run(["worktree", "add", path.path, branch], in: repository)
        guard let worktree = try await list().first(where: { Self.samePath($0.path, path) }) else {
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
        let existing = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(where: { [entry, "\(Self.directoryName)/", Self.directoryName, "/\(Self.directoryName)"].contains($0) }) else {
            return
        }
        try FileManager.default.createDirectory(at: excludeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + entry + "\n").write(to: excludeFile, atomically: true, encoding: .utf8)
    }

    public func recover() async throws -> WorktreeRecovery {
        try await ensureExcluded()
        let pruned = try await list().filter(\.isPrunable)
        if !pruned.isEmpty {
            try await git.run(["worktree", "prune"], in: repository)
        }
        let worktrees = try await list()
        let registered = Set(worktrees.map { Self.canonicalPath($0.path) })
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: crewDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let orphaned = directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !registered.contains(Self.canonicalPath($0)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return WorktreeRecovery(worktrees: worktrees, pruned: pruned, orphanedDirectories: orphaned)
    }

    public func deleteOrphanedDirectory(_ directory: URL) throws {
        guard isInsideCrewDirectory(directory), !Self.samePath(directory, crewDirectory) else {
            throw WorktreeError.outsideCrewDirectory(directory)
        }
        try FileManager.default.removeItem(at: directory)
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
        Self.canonicalPath(url).hasPrefix(Self.canonicalPath(crewDirectory) + "/")
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
