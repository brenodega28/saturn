import Foundation

public struct RunSpecLink: Sendable, Hashable, Codable {
    public var projectId: Int64
    public var taskId: Int64
    public var path: String
    public var branch: String

    public init(projectId: Int64, taskId: Int64, path: String, branch: String) {
        self.projectId = projectId
        self.taskId = taskId
        self.path = path
        self.branch = branch
    }

    enum CodingKeys: String, CodingKey {
        case path, branch
        case projectId = "project_id"
        case taskId = "task_id"
    }

    public static func branch(runId: Int64) -> String {
        "saturn/spec-run-\(runId)"
    }
}

public struct SpecFile: Sendable, Hashable, Identifiable {
    public var url: URL
    public var relativePath: String?
    public var document: SpecDocument?
    public var taskId: Int64?

    public var id: String { url.path }
    public var isDraft: Bool { taskId != nil }

    public init(url: URL, relativePath: String? = nil, document: SpecDocument?, taskId: Int64? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.document = document
        self.taskId = taskId
    }
}

public struct SpecStore: Sendable {
    public let paths: AppPaths
    public let database: AppDatabase?

    public init(paths: AppPaths, database: AppDatabase? = nil) {
        self.paths = paths
        self.database = database
    }

    public func draftURL(projectId: Int64, taskId: Int64) -> URL {
        paths.specDraft(projectId: projectId, taskId: taskId)
    }

    public func draft(projectId: Int64, taskId: Int64) throws -> SpecDocument? {
        let url = draftURL(projectId: projectId, taskId: taskId)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try SpecDocument(markdown: text)
    }

    public func write(_ document: SpecDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.markdown.write(to: url, atomically: true, encoding: .utf8)
        try writePage(document, for: url)
    }

    public func writePage(_ document: SpecDocument, for draft: URL) throws {
        let page = SpecPageRenderer.pageURL(for: draft)
        let taskId = Int64(draft.deletingPathExtension().lastPathComponent)
        let html = SpecPageRenderer().render(document, workflow: taskId.flatMap { workflow(for: document, taskId: $0) })
        guard (try? String(contentsOf: page, encoding: .utf8)) != html else { return }
        try html.write(to: page, atomically: false, encoding: .utf8)
    }

    public func workflow(for document: SpecDocument, taskId: Int64) -> WorkflowDefinition? {
        guard let database, let chat = try? database.task(id: taskId), let project = try? database.project(id: chat.projectId) else { return nil }
        let proposal = (try? database.leadMessages(taskId: taskId))?.last { $0.kind == .proposal && $0.status == .open }?.workflow
        let id = document.workflow ?? proposal ?? LeadChat.specWorkflow
        return ProjectConfigLoader.load(repository: project.filesRoot).workflow(id)
    }

    public func pageURL(projectId: Int64, taskId: Int64) -> URL {
        SpecPageRenderer.pageURL(for: draftURL(projectId: projectId, taskId: taskId))
    }

    public func ensurePage(projectId: Int64, taskId: Int64) -> URL? {
        let page = pageURL(projectId: projectId, taskId: taskId)
        if let document = try? draft(projectId: projectId, taskId: taskId) {
            try? writePage(document, for: draftURL(projectId: projectId, taskId: taskId))
        }
        return FileManager.default.fileExists(atPath: page.path) ? page : nil
    }

    public func link(runId: Int64) -> RunSpecLink? {
        guard let data = try? Data(contentsOf: paths.runSpecLink(runId: runId)) else { return nil }
        return try? JSONDecoder().decode(RunSpecLink.self, from: data)
    }

    public func save(_ link: RunSpecLink, runId: Int64) throws {
        let url = paths.runSpecLink(runId: runId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(link).write(to: url, options: .atomic)
    }

    public func runSpec(runId: Int64) -> (link: RunSpecLink, url: URL, document: SpecDocument)? {
        guard let link = link(runId: runId) else { return nil }
        let url = draftURL(projectId: link.projectId, taskId: link.taskId)
        guard let text = try? String(contentsOf: url, encoding: .utf8), let document = try? SpecDocument(markdown: text) else { return nil }
        return (link, url, document)
    }

    public func drafts(projectId: Int64) -> [SpecFile] {
        let directory = paths.specDraftsDirectory(projectId: projectId)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> SpecFile? in
                guard let taskId = Int64(url.deletingPathExtension().lastPathComponent) else { return nil }
                let document = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? SpecDocument(markdown: $0) }
                return SpecFile(url: url, relativePath: committedPath(projectId: projectId, taskId: taskId), document: document, taskId: taskId)
            }
            .sorted { ($0.taskId ?? 0) > ($1.taskId ?? 0) }
    }

    public func committedPath(projectId: Int64, taskId: Int64) -> String? {
        links().filter { $0.link.projectId == projectId && $0.link.taskId == taskId }.max { $0.runId < $1.runId }?.link.path
    }

    func links() -> [(runId: Int64, link: RunSpecLink)] {
        let runs = paths.root.appending(path: "runs", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let runId = Int64(folder.lastPathComponent), let link = link(runId: runId) else { return nil }
            return (runId, link)
        }
    }

    public static func files(in repository: URL, config: SpecsConfig) -> [SpecFile] {
        let directory = config.directory(in: repository)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let document = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? SpecDocument(markdown: $0) }
                return SpecFile(url: url, relativePath: "\(config.folder)/\(url.lastPathComponent)", document: document)
            }
    }

    public static func availablePath(title: String, folder: String, repository: URL, taken: Set<String> = []) -> String {
        let slug = Slug.make(title).nilIfEmpty ?? "spec"
        var candidate = "\(folder)/\(slug).md"
        var counter = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: repository.appending(path: candidate).path) {
            candidate = "\(folder)/\(slug)-\(counter).md"
            counter += 1
        }
        return candidate
    }

    public func pathsInUse(projectId: Int64, excludingTask taskId: Int64) -> Set<String> {
        Set(links().filter { $0.link.projectId == projectId && $0.link.taskId != taskId }.map(\.link.path))
    }
}
