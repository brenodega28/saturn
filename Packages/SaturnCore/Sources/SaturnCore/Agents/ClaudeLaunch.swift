import Foundation

public enum AgentModel: String, CaseIterable, Sendable, Identifiable {
    case sonnet
    case opus
    case haiku
    case fable

    public var id: Self { self }

    public var title: String {
        switch self {
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .haiku: "Haiku"
        case .fable: "Fable"
        }
    }
}

public enum AgentPermissions {
    public static let commands = [
        "git status", "git diff", "git log", "git show", "git add", "git commit", "git restore",
        "git stash", "git branch", "git rev-parse", "git ls-files", "git mv", "git rm", "git grep", "git merge",
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "which", "mkdir", "touch", "echo",
        "npm test", "npm run", "npm ci", "npm install", "npx", "pnpm", "yarn", "bun",
        "pytest", "python -m pytest", "python3 -m pytest", "python -m unittest", "python3 -m unittest", "node --test", "uv run", "uv sync", "poetry run", "pip install",
        "swift build", "swift test", "xcodebuild",
        "cargo build", "cargo test", "cargo check", "cargo fmt", "cargo clippy",
        "go build", "go test", "go vet",
        "make", "bundle exec", "rake", "rspec", "mix test", "./gradlew", "gradle", "mvn", "dotnet build", "dotnet test",
    ]

    public static let writingGitCommands = ["git add", "git commit", "git restore", "git stash", "git mv", "git rm", "git merge"]
    public static let installCommands = ["npm ci", "npm install", "pip install", "uv sync", "uv add", "pnpm install", "pnpm add", "yarn add", "yarn install", "bun install", "bun add", "poetry install", "poetry add", "bundle install", "cargo add", "go get"]
    public static let networkCommands = ["curl", "wget", "ssh", "scp", "nc"]
    public static let inspectionCommands = [
        "git status", "git diff", "git log", "git show", "git branch", "git rev-parse", "git ls-files", "git grep",
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "which",
    ]

    public static var readOnlyCommands: [String] {
        commands.filter { !writingGitCommands.contains($0) }
    }

    public static let tools = ["Read", "Glob", "Grep"]
    public static let fileWritingTools = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    public static let webTools = ["WebFetch", "WebSearch"]
    public static let artifactReadTool = "Artifact(read)"
    public static let artifactDataTools = ["ArtifactData", "ArtifactComments", "ArtifactCheck"]
    public static let artifactTools = [artifactReadTool] + artifactDataTools
    public static let artifactEnvironment = ["CLAUDE_CODE_ARTIFACT": "1"]

    public static func builtInTools(readOnly: Bool, extraAllowedTools: [String]) -> [String] {
        ["Bash", "Skill"] + tools + (readOnly ? [] : fileWritingTools)
            + (webTools + artifactTools).filter(extraAllowedTools.contains).map(toolName)
    }

    static func toolName(_ rule: String) -> String {
        String(rule.prefix { $0 != "(" })
    }

    public static let projectSkillsOnlySettings = #"{"disableBundledSkills":true,"skillOverrides":{"design":"off","doctor":"off","plugin-authoring":"off"}}"#

    public static func readOnlyAllowedTools() -> [String] {
        tools + readOnlyCommands.map { "Bash(\($0):*)" }
    }

    public static func allowedTools(worktree: URL) -> [String] {
        let scope = "/" + realPath(of: worktree) + "/**"
        return tools
            + fileWritingTools.map { "\($0)(\(scope))" }
            + commands.map { "Bash(\($0):*)" }
    }
}

func realPath(of url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(resolved) }
    return String(decoding: Data(bytes: resolved, count: strlen(resolved)), as: UTF8.self)
}

public struct ClaudeLaunch: Sendable, Equatable {
    public enum Session: Sendable, Equatable {
        case new(String)
        case resume(String)

        public var id: String {
            switch self {
            case .new(let id), .resume(let id): id
            }
        }
    }

    public let executable: URL
    public let worktree: URL
    public let session: Session
    public let model: String
    public let systemPrompt: String
    public let environment: [String: String]
    public var readOnly: Bool
    public var additionalDirectories: [URL]
    public var extraArguments: [String]
    public var extraAllowedTools: [String]
    public var hooks: JSONValue?
    public var permissions: PermissionPolicy?
    public var askTools: [String]

    public init(
        executable: URL,
        worktree: URL,
        session: Session,
        model: String,
        systemPrompt: String,
        environment: [String: String],
        readOnly: Bool = false,
        additionalDirectories: [URL] = [],
        extraArguments: [String] = [],
        extraAllowedTools: [String] = [],
        hooks: JSONValue? = nil,
        permissions: PermissionPolicy? = nil,
        askTools: [String] = []
    ) {
        self.permissions = permissions
        self.askTools = askTools
        self.executable = executable
        self.worktree = worktree
        self.session = session
        self.model = model
        self.systemPrompt = systemPrompt
        self.environment = environment
        self.readOnly = readOnly
        self.additionalDirectories = additionalDirectories
        self.extraArguments = extraArguments
        self.extraAllowedTools = extraAllowedTools
        self.hooks = hooks
    }

    public var settings: String {
        guard let hooks, case .object(var fields)? = JSONValue.parse(AgentPermissions.projectSkillsOnlySettings) else {
            return AgentPermissions.projectSkillsOnlySettings
        }
        fields["hooks"] = hooks
        return JSONValue.object(fields).compactJSON
    }

    public var workingDirectory: URL { worktree }

    func resolvedPath(of url: URL) -> String {
        realPath(of: url)
    }

    public var invocation: (executable: URL, arguments: [String], environment: [String: String], directory: URL?) {
        (executable, arguments, processEnvironment, worktree)
    }

    public var processEnvironment: [String: String] {
        guard extraAllowedTools.contains(AgentPermissions.artifactReadTool) else { return environment }
        return environment.merging(AgentPermissions.artifactEnvironment) { _, artifact in artifact }
    }

    public var arguments: [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--permission-mode", "dontAsk",
            "--setting-sources", "project",
            "--tools", tools.joined(separator: ","),
            "--settings", settings,
            "--append-system-prompt", systemPrompt,
        ]
        switch session {
        case .new(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        for directory in additionalDirectories {
            arguments += ["--add-dir", resolvedPath(of: directory)]
        }
        if !writes {
            arguments.append("--disallowedTools")
            arguments += AgentPermissions.fileWritingTools
        }
        arguments += extraArguments
        arguments.append("--allowedTools")
        arguments += allowedTools
        arguments += extraAllowedTools
        return arguments
    }

    var writes: Bool {
        guard !readOnly else { return false }
        guard let permissions else { return true }
        return permissions.level(.editFiles) != .never
    }

    var tools: [String] {
        var tools = AgentPermissions.builtInTools(readOnly: !writes, extraAllowedTools: extraAllowedTools)
        if let permissions, !permissions.hasBash {
            tools.removeAll { $0 == "Bash" }
        }
        for tool in askTools.map(AgentPermissions.toolName) where !tools.contains(tool) { tools.append(tool) }
        return tools
    }

    var allowedTools: [String] {
        guard let permissions else {
            guard !readOnly else { return AgentPermissions.readOnlyAllowedTools() }
            return AgentPermissions.allowedTools(worktree: worktree)
        }
        let commands = permissions.commands.map { "Bash(\($0):*)" }
        guard writes, permissions.level(.editFiles) == .allow else { return AgentPermissions.tools + commands }
        let scope = "/" + resolvedPath(of: worktree) + "/**"
        return AgentPermissions.tools + AgentPermissions.fileWritingTools.map { "\($0)(\(scope))" } + commands
    }

    public static func readOnlySystemPrompt(agentName: String, directory: URL, canOpenWorktree: Bool = false, shellRules rules: String? = nil) -> String {
        let editing = canOpenWorktree
            ? "You start read-only and never edit, create or delete files here or commit. When you must change code yourself, "
                + "call `\(HandoffTool.openWorktree.qualifiedName)` to get your own worktree and branch; your next turn runs there with write access."
            : "You never edit, create or delete files and never commit. Report what you find; the coding agents and the user make the changes."
        return """
        You are \(agentName), a read-only agent run by Saturn. You work from \(directory.path) and can read every file \
        and worktree you are given, run tests and inspect history. \(editing)

        \(selfServiceRule)

        \(rules ?? shellRules(PermissionPolicy(profile: PermissionsConfig().resolve(for: nil, readOnly: true), readOnly: true)))
        """
    }

    public static let selfServiceRule = "Do everything you can yourself: run the commands, read the files, fix the environment. Hand a step to the user only as a last resort, when your tools or permissions can't do it. Whenever you need the user to do something, give the exact commands to run, each in its own code block, with the directory to run it from."

    static let askingTopics: [(PermissionCapability, String)] = [
        (.riskyCommands, "risky commands (deleting files with rm, git reset --hard or git clean; force-deleting branches; kill, sudo, chmod; publishing or changing things outside the repo such as gh pr create, npm publish, docker push, kubectl apply and cloud CLIs; writing outside your worktree)"),
        (.installPackages, "installing or removing packages"),
        (.network, "network tools such as curl, wget and ssh"),
        (.gitPush, "git push"),
    ]

    public static func shellRules(_ policy: PermissionPolicy, guarded: Bool = true) -> String {
        let writing = policy.level(.editFiles) != .never
        let editRule = writing ? "Create and change files with the Edit and Write tools rather than through the shell. " : ""
        guard guarded else {
            let commands = policy.commands.map { "`\($0)`" }.joined(separator: ", ")
            return "Shell rules: only these commands are allowed, each with any arguments: \(commands). \(editRule)"
                + "If a command is denied, try the allowed equivalent before giving up, and tell the user exactly what you couldn't run."
        }
        var lines = ["Shell rules: run the commands you need; chaining, pipes, redirects and subshells are fine."]
        if policy.level(.runShell) == .ask {
            lines.append("Every command needs the user’s OK the first time, except " + policy.commands.map { "`\($0)`" }.joined(separator: ", ") + ".")
        }
        let asking = askingTopics.filter { policy.level($0.0) == .ask }.map(\.1)
        if !asking.isEmpty {
            lines.append("These need the user’s OK the first time: " + asking.joined(separator: "; ") + ".")
        }
        if policy.readOnly, policy.level(.riskyCommands) == .ask {
            lines.append("Because you are read-only, commands that change files (mv, cp, mkdir, touch, sed -i, tee, > redirects, formatters that write, and git commands that change the repo) need the user’s OK too.")
        }
        let never = askingTopics.filter { policy.level($0.0) == .never }.map(\.1)
        if !never.isEmpty {
            lines.append("Never allowed: " + never.joined(separator: "; ") + ".")
        }
        if !policy.profile.extraCommands.isEmpty, policy.level(.runShell) != .never {
            lines.append("Always allowed without asking: " + policy.profile.extraCommands.map { "`\($0)`" }.joined(separator: ", ") + ".")
        }
        lines.append(editRule + "If a command is denied, find another way and tell the user exactly what you couldn't run.")
        return lines.joined(separator: " ")
    }

    public static func systemPrompt(agentName: String, worktree: URL, branch: String?, shellRules rules: String? = nil) -> String {
        """
        You are \(agentName), a coding agent run by Saturn. You work alone in the git worktree at \(worktree.path)\
        \(branch.map { " on branch \($0)" } ?? ""). Keep all changes inside this worktree. \
        Run the project's tests when you change behavior. Commit finished work to your branch with clear messages; never push.

        \(selfServiceRule)

        \(rules ?? shellRules(PermissionPolicy(profile: PermissionsConfig().resolve(for: .builder), readOnly: false)))
        """
    }

    public static func askGuide(_ policy: PermissionPolicy) -> String? {
        let asks = PermissionCapability.allCases.filter { policy.level($0) == .ask }
        guard !asks.isEmpty else { return nil }
        return "Some actions need the user’s OK first: " + asks.map { $0.title.lowercased() }.joined(separator: ", ")
            + ". Just try the action; Saturn holds it, asks the user once in your chat and messages you with the answer. "
            + "Once the user allows a kind of command, you and every other agent in the chat can run similar commands without asking again; once they say no, don’t retry it. "
            + "Carry on with other work or end your turn while you wait."
    }
}
