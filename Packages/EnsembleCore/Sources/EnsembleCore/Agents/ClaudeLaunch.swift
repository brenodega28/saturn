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

    public static var readOnlyCommands: [String] {
        commands.filter { !writingGitCommands.contains($0) }
    }

    public static let tools = ["Read", "Glob", "Grep"]
    public static let fileWritingTools = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    public static let webTools = ["WebFetch", "WebSearch"]
    public static let artifactTools = ["ArtifactData", "ArtifactComments", "ArtifactCheck"]

    public static func builtInTools(readOnly: Bool, extraAllowedTools: [String]) -> [String] {
        ["Bash", "Skill"] + tools + (readOnly ? [] : fileWritingTools) + webTools.filter(extraAllowedTools.contains)
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
        extraAllowedTools: [String] = []
    ) {
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
    }

    public var workingDirectory: URL { worktree }

    public var arguments: [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--permission-mode", "dontAsk",
            "--setting-sources", "project",
            "--tools", AgentPermissions.builtInTools(readOnly: readOnly, extraAllowedTools: extraAllowedTools).joined(separator: ","),
            "--settings", AgentPermissions.projectSkillsOnlySettings,
            "--append-system-prompt", systemPrompt,
        ]
        switch session {
        case .new(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        for directory in additionalDirectories {
            arguments += ["--add-dir", realPath(of: directory)]
        }
        if readOnly {
            arguments.append("--disallowedTools")
            arguments += AgentPermissions.fileWritingTools
        }
        arguments += extraArguments
        arguments.append("--allowedTools")
        arguments += readOnly ? AgentPermissions.readOnlyAllowedTools() : AgentPermissions.allowedTools(worktree: worktree)
        arguments += extraAllowedTools
        return arguments
    }

    public static func readOnlySystemPrompt(agentName: String, directory: URL) -> String {
        """
        You are \(agentName), a read-only agent run by Ensemble. You work from \(directory.path) and can read every file \
        and worktree you are given, run tests and inspect history, but you never edit, create or delete files and never commit. \
        Report what you find; the coding agents and the user make the changes.

        \(shellRules(writing: false))
        """
    }

    public static func shellRules(writing: Bool) -> String {
        let commands = (writing ? AgentPermissions.commands : AgentPermissions.commands.filter { !AgentPermissions.writingGitCommands.contains($0) })
            .map { "`\($0)`" }
            .joined(separator: ", ")
        return """
            Shell rules: only these commands are allowed, each with any arguments: \(commands). \
            Run one command per Bash call; chains with &&, ;, |, subshells, heredocs and output redirection (>) are denied. \
            \(writing ? "Create and change files with the Edit and Write tools, never through the shell. " : "")\
            If a command is denied, try the allowed equivalent on its own before giving up, and tell the user exactly what you couldn't run.
            """
    }

    public static func systemPrompt(agentName: String, worktree: URL, branch: String?) -> String {
        """
        You are \(agentName), a coding agent run by Ensemble. You work alone in the git worktree at \(worktree.path)\
        \(branch.map { " on branch \($0)" } ?? ""). Keep all changes inside this worktree. \
        Run the project's tests when you change behavior. Commit finished work to your branch with clear messages; never push.

        \(shellRules(writing: true))
        """
    }
}
