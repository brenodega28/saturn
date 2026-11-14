import Foundation
import Yams

public struct DetectedTechnology: Sendable, Hashable, Identifiable {
    public var name: String
    public var location: String

    public var id: String { name }

    public init(name: String, location: String) {
        self.name = name
        self.location = location
    }
}

public struct ProjectScan: Sendable, Hashable {
    public var found: [DetectedTechnology]
    public var skillReasons: [String: String]
    public var checks: CheckSuggestions
    public var docs: [String]
    public var baseBranch: String?

    public init(
        found: [DetectedTechnology] = [], skillReasons: [String: String] = [:], checks: CheckSuggestions = CheckSuggestions(checks: [], protectedPaths: [], evidence: []),
        docs: [String] = [], baseBranch: String? = nil
    ) {
        self.found = found
        self.skillReasons = skillReasons
        self.checks = checks
        self.docs = docs
        self.baseBranch = baseBranch
    }

    public var suggestedSkills: [String] {
        ProjectSetup.skillCatalog.map(\.name).filter { skillReasons[$0] != nil }
    }
}

public enum ProjectScanner {
    public static let docCandidates = ["AGENTS.md", "CLAUDE.md", "README.md", "CONTRIBUTING.md", "ARCHITECTURE.md", "docs/ROADMAP.md", "spec/mission.md", "spec/roadmap.md"]

    public static func scan(repository: URL, git: GitClient? = nil, files: URL? = nil) async -> ProjectScan {
        var scan = scanFiles(repository: files ?? repository)
        if let git {
            scan.baseBranch = await defaultBranch(of: repository, git: git)
        }
        return scan
    }

    static func defaultBranch(of repository: URL, git: GitClient) async -> String? {
        if let remoteHead = try? await git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repository) {
            let name = remoteHead.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/") { return String(name[name.index(after: slash)...]) }
        }
        for candidate in ["main", "master"] where (try? await git.hasCommit("refs/heads/\(candidate)", in: repository)) == true {
            return candidate
        }
        return try? await git.currentBranch(in: repository)
    }

    public static func scanFiles(repository: URL) -> ProjectScan {
        let files = CheckDetector.listFiles(in: repository)
        var scan = ProjectScan(checks: CheckDetector.suggest(repository: repository))
        func read(_ path: String) -> String { (try? String(contentsOf: repository.appending(path: path), encoding: .utf8)) ?? "" }
        func folder(of path: String) -> String {
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "repo root" : parent + "/"
        }
        func add(_ name: String, _ location: String) {
            if !scan.found.contains(where: { $0.name == name }) { scan.found.append(DetectedTechnology(name: name, location: location)) }
        }

        if let manage = files.first(where: { ($0 as NSString).lastPathComponent == "manage.py" }) {
            let where_ = folder(of: manage)
            add("Django", "\(where_) · manage.py")
            scan.skillReasons["django-developer"] = where_
        }
        let packages = files.filter { ($0 as NSString).lastPathComponent == "package.json" }
        for package in packages {
            let text = read(package)
            if text.contains("\"react\"") {
                let where_ = folder(of: package)
                add(text.contains("\"vite\"") ? "React + Vite" : "React", package)
                scan.skillReasons["react-developer"] = scan.skillReasons["react-developer"] ?? where_
            } else if packages.count == 1 {
                add("Node.js", package)
            }
            if text.contains("\"vitest\"") { add("Vitest", package) }
            if text.contains("\"jest\"") { add("Jest", package) }
            if text.contains("\"@playwright/test\"") { add("Playwright", package) }
        }
        let pythonTests = files.first { ["pytest.ini", "conftest.py"].contains(($0 as NSString).lastPathComponent) }
        if let pythonTests { add("pytest", pythonTests) } else if read("pyproject.toml").contains("[tool.pytest") { add("pytest", "pyproject.toml") }
        if files.contains("Package.swift") { add("Swift package", "Package.swift") }
        if files.contains("project.yml") || files.contains(where: { $0.hasSuffix(".xcodeproj/project.pbxproj") }) { add("Xcode project", files.contains("project.yml") ? "project.yml" : "xcodeproj") }
        if files.contains("go.mod") { add("Go", "go.mod") }
        if files.contains("Cargo.toml") { add("Rust", "Cargo.toml") }
        if files.contains("Gemfile") { add("Ruby", "Gemfile") }
        if let compose = files.first(where: { ($0 as NSString).lastPathComponent.hasPrefix("docker-compose") || ($0 as NSString).lastPathComponent.hasPrefix("compose.y") }) {
            let text = read(compose).lowercased()
            if text.contains("postgres") { add("PostgreSQL", compose) }
            if text.contains("mysql") { add("MySQL", compose) }
            if text.contains("redis") { add("Redis", compose) }
        }
        scan.docs = docCandidates.filter(files.contains)
        if files.contains("AGENTS.md") { add("AGENTS.md", "repo root") }
        return scan
    }
}

public struct ProjectSetupPlan: Sendable, Hashable {
    public var baseBranch: String
    public var branchPrefix: String
    public var skills: [String]
    public var workflows: [WorkflowDefinition]
    public var defaultWorkflow: String
    public var endAction: EndAction
    public var approvePlans: Bool
    public var checks: ChecksConfig?
    public var weeklyBudgetUSD: Double?
    public var monthlyBudgetUSD: Double?
    public var perRunBudgetUSD: Double?
    public var maxConcurrentAgents: Int
    public var testsWithoutAsking: Bool
    public var networkWithoutAsking: Bool
    public var installsWithoutAsking: Bool
    public var docs: [String]

    public init(
        baseBranch: String = "main", branchPrefix: String = ProjectPreferences.defaultBranchPrefix,
        skills: [String] = [], workflows: [WorkflowDefinition] = [], defaultWorkflow: String = "feature-delivery",
        endAction: EndAction = .merge, approvePlans: Bool = true, checks: ChecksConfig? = nil,
        weeklyBudgetUSD: Double? = 60, monthlyBudgetUSD: Double? = 200, perRunBudgetUSD: Double? = 8, maxConcurrentAgents: Int = 4,
        testsWithoutAsking: Bool = true, networkWithoutAsking: Bool = false, installsWithoutAsking: Bool = false, docs: [String] = []
    ) {
        self.baseBranch = baseBranch
        self.branchPrefix = branchPrefix
        self.skills = skills
        self.workflows = workflows
        self.defaultWorkflow = defaultWorkflow
        self.endAction = endAction
        self.approvePlans = approvePlans
        self.checks = checks
        self.weeklyBudgetUSD = weeklyBudgetUSD
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.perRunBudgetUSD = perRunBudgetUSD
        self.maxConcurrentAgents = maxConcurrentAgents
        self.testsWithoutAsking = testsWithoutAsking
        self.networkWithoutAsking = networkWithoutAsking
        self.installsWithoutAsking = installsWithoutAsking
        self.docs = docs
    }

    public static func recommended(for scan: ProjectScan) -> ProjectSetupPlan {
        ProjectSetupPlan(
            baseBranch: scan.baseBranch ?? "main",
            skills: scan.suggestedSkills,
            workflows: ProjectSetup.workflowCatalog,
            checks: scan.checks.checks.isEmpty ? nil : scan.checks.config,
            docs: scan.docs.filter { $0 != "CLAUDE.md" && $0 != "README.md" }
        )
    }

    public var permissions: PermissionsConfig {
        var config = PermissionsConfig()
        if let index = config.profiles.firstIndex(where: { $0.id == "developer" }) {
            config.profiles[index].levels[.runShell] = testsWithoutAsking ? .allow : .ask
            config.profiles[index].levels[.network] = networkWithoutAsking ? .allow : .ask
            config.profiles[index].levels[.installPackages] = installsWithoutAsking ? .allow : .ask
        }
        return config
    }

    public var preferences: ProjectPreferences {
        ProjectPreferences(
            baseBranch: baseBranch.nilIfBlank, branchPrefix: ProjectPreferences.cleanPrefix(branchPrefix),
            defaultWorkflow: defaultWorkflow, approvePlans: approvePlans
        )
    }

    public func settings(updating settings: ProjectSettings) -> ProjectSettings {
        var settings = settings
        settings.weeklyBudgetUSD = weeklyBudgetUSD
        settings.monthlyBudgetUSD = monthlyBudgetUSD
        settings.maxConcurrentAgents = max(1, maxConcurrentAgents)
        return settings
    }

    public func installedWorkflows() -> [WorkflowDefinition] {
        workflows.map { workflow in
            var workflow = workflow
            workflow.end.action = endAction
            if let perRunBudgetUSD { workflow.budget = perRunBudgetUSD }
            return workflow
        }
    }

    public func apply(to repository: URL) throws {
        let root = ProjectConfig.directory(in: repository)
        try FileManager.default.createDirectory(at: root.appending(path: "workflows"), withIntermediateDirectories: true)
        let ignore = root.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try "memory/\nlocal.yaml\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        for skill in ProjectSetup.skillCatalog where skills.contains(skill.name) {
            _ = try skill.install(in: repository)
        }
        for workflow in installedWorkflows() { try ProjectConfigLoader.write(workflow, repository: repository) }
        if let checks { try ProjectConfigLoader.write(checks, repository: repository) }
        try ProjectConfigLoader.write(permissions, repository: repository)
        try ProjectConfigLoader.write(preferences, repository: repository)
        if !docs.isEmpty {
            var index = ProjectConfigLoader.load(repository: repository).docs
            for path in docs where !index.docs.contains(where: { $0.path == path }) {
                index.docs.append(DocEntry(title: (path as NSString).lastPathComponent, path: path, readers: .all))
            }
            try ProjectConfigLoader.write(index, repository: repository)
        }
    }
}

public enum ProjectSetup {
    public static var skillCatalog: [BundledSkill] {
        var skills: [BundledSkill] = []
        for skill in CrewTemplates.bundled.flatMap(\.bundledSkills) where !skills.contains(where: { $0.name == skill.name }) {
            skills.append(skill)
        }
        return skills
    }

    public static var workflowCatalog: [WorkflowDefinition] {
        let defaults = Bundle.module.url(forResource: "Defaults", withExtension: nil).map { loadWorkflows(in: $0.appending(path: "workflows")) } ?? []
        let hotfix = (try? YAMLDecoder().decode(WorkflowDefinition.self, from: hotfixYAML)).map { workflow -> WorkflowDefinition in
            var workflow = workflow
            workflow.id = "hotfix"
            return workflow
        }
        let order = ["feature-delivery", "small-task", "hotfix"]
        return (defaults + [hotfix].compactMap(\.self)).sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    static let hotfixYAML = """
    name: Hotfix
    version: 1
    description: Smallest path for urgent fixes. One builder fixes it, the checks still have to pass, you approve.
    trigger:
      sources: [chat]
      labels: [hotfix]
    budget: 5
    steps:
      - id: build
        type: agent
        title: Fix
        agent: builder
        instructions: Make the smallest change that fixes the problem, add a test that reproduces it, run the tests, and commit.
        next: checks
      - id: checks
        type: check
        title: Run the checks
        next: approve
      - id: approve
        type: approval
        title: You approve
        routes:
          approved: end
          changes_requested: build
    end:
      action: pull_request
    """

    static func loadWorkflows(in directory: URL) -> [WorkflowDefinition] {
        yamlFiles(in: directory).compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8), var workflow = try? YAMLDecoder().decode(WorkflowDefinition.self, from: text) else { return nil }
            workflow.id = file.deletingPathExtension().lastPathComponent
            return workflow
        }
    }

    private static func yamlFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
