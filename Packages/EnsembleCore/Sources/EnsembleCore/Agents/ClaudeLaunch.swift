import Foundation

public enum AgentModel: String, CaseIterable, Sendable, Identifiable {
    case sonnet
    case opus
    case haiku

    public var id: Self { self }

    public var title: String {
        switch self {
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .haiku: "Haiku"
        }
    }
}

public enum AgentPermissions {
    public static let commands = [
        "git status", "git diff", "git log", "git show", "git add", "git commit", "git restore",
        "git stash", "git branch", "git rev-parse", "git ls-files", "git mv", "git rm", "git grep",
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "which", "mkdir", "touch", "echo",
        "npm test", "npm run", "npm ci", "npm install", "npx", "pnpm", "yarn", "bun",
        "pytest", "python -m pytest", "python3 -m pytest", "python -m unittest", "python3 -m unittest", "node --test", "uv run", "uv sync", "poetry run", "pip install",
        "swift build", "swift test", "xcodebuild",
        "cargo build", "cargo test", "cargo check", "cargo fmt", "cargo clippy",
        "go build", "go test", "go vet",
        "make", "bundle exec", "rake", "rspec", "mix test", "./gradlew", "gradle", "mvn", "dotnet build", "dotnet test",
    ]

    public static let tools = ["Read", "Glob", "Grep", "TodoWrite"]
    public static let fileWritingTools = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

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

    public init(executable: URL, worktree: URL, session: Session, model: String, systemPrompt: String, environment: [String: String]) {
        self.executable = executable
        self.worktree = worktree
        self.session = session
        self.model = model
        self.systemPrompt = systemPrompt
        self.environment = environment
    }

    public var arguments: [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--permission-mode", "dontAsk",
            "--setting-sources", "project",
            "--append-system-prompt", systemPrompt,
        ]
        switch session {
        case .new(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        arguments.append("--allowedTools")
        arguments += AgentPermissions.allowedTools(worktree: worktree)
        return arguments
    }

    public static func systemPrompt(agentName: String, worktree: URL, branch: String?) -> String {
        """
        You are \(agentName), a coding agent run by Ensemble. You work alone in the git worktree at \(worktree.path)\
        \(branch.map { " on branch \($0)" } ?? ""). Keep all changes inside this worktree. \
        Run the project's tests when you change behavior. Commit finished work to your branch with clear messages; never push. \
        Some shell commands are blocked: if one is denied, use another approach or say what you need from the user.
        """
    }
}
