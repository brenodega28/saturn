import Foundation
import GRDB
import Testing
@testable import EnsembleCore

@Suite struct ChecksConfigTests {
    @Test func decodesAndEncodesChecksYAML() throws {
        let yaml = """
        checks:
          - name: format
            kind: format
            command: npm run format:check
            on_edit: true
          - name: test
            kind: test
            command: npm test
            timeout_minutes: 20
        protected_paths:
          - tests/**
          - "*_test.go"
        max_rounds: 3
        """
        let repo = FileManager.default.temporaryDirectory.appending(path: "checks-yaml-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: ProjectConfig.directory(in: repo), withIntermediateDirectories: true)
        try yaml.write(to: ChecksConfig.file(in: repo), atomically: true, encoding: .utf8)
        let loaded = ProjectConfigLoader.load(repository: repo)
        #expect(loaded.issues.isEmpty)
        let config = try #require(loaded.checks)
        #expect(config.checks.map(\.name) == ["format", "test"])
        #expect(config.checks[0].onEdit && config.checks[0].timeoutMinutes == 10)
        #expect(config.checks[1].timeoutMinutes == 20)
        #expect(config.maxRounds == 3)
        #expect(config.editChecks.map(\.name) == ["format"])
        #expect(config.isProtected("tests/unit/test_refunds.py"))
        #expect(config.isProtected("pkg/api/refund_test.go"))
        #expect(!config.isProtected("src/refunds.py"))
        try ProjectConfigLoader.write(config, repository: repo)
        #expect(ProjectConfigLoader.load(repository: repo).checks == config)
    }

    @Test func reportsProblemsInChecksAndCheckSteps() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "checks-config-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repo) }
        try ProjectConfigLoader.write(ChecksConfig(
            checks: [CheckDefinition(name: "lint", kind: .lint, command: "make lint"), CheckDefinition(name: "lint", kind: .lint, command: " ")],
            protectedPaths: ["/abs/**"], maxRounds: 0
        ), repository: repo)
        try ProjectConfigLoader.write(WorkflowDefinition(id: "checked", name: "Checked", steps: [
            WorkflowStep(id: "verify", type: .check, checks: ["ghost"], testFirst: true),
        ]), repository: repo)

        let messages = ProjectConfigLoader.load(repository: repo).issues.map { "\($0.file): \($0.message)" }
        #expect(messages.contains(".ensemble/checks.yaml: checks[1]: the name “lint” is used twice"))
        #expect(messages.contains(".ensemble/checks.yaml: checks[1]: needs a command"))
        #expect(messages.contains(".ensemble/checks.yaml: max_rounds must be at least 1"))
        #expect(messages.contains(".ensemble/checks.yaml: protected_paths: “/abs/**” must be a relative glob such as tests/**"))
        #expect(messages.contains(".ensemble/workflows/checked.yaml: steps.verify: check “ghost” doesn’t exist"))
        #expect(messages.contains(".ensemble/workflows/checked.yaml: steps.verify: test_first needs a check of kind test"))
    }

    @Test func aCheckStepWithoutChecksIsOnlyReportedWhenItNamesChecks() throws {
        let plain = ProjectConfig(workflows: [WorkflowDefinition(id: "w", name: "W", steps: [WorkflowStep(id: "verify", type: .check)])])
        #expect(ConfigValidator.validate(plain).isEmpty)
        let named = ProjectConfig(workflows: [WorkflowDefinition(id: "w", name: "W", steps: [WorkflowStep(id: "verify", type: .check, checks: ["unit"])])])
        #expect(ConfigValidator.validate(named).map(\.message) == ["steps.verify: needs checks in .ensemble/checks.yaml"])
    }

    @Test func hookSettingsCoverOnlyWhatIsConfigured() throws {
        let url = try #require(URL(string: "http://127.0.0.1:9/hooks/token"))
        let full = ChecksConfig(
            checks: [CheckDefinition(name: "format", kind: .format, command: "f", onEdit: true), CheckDefinition(name: "test", kind: .test, command: "t", timeoutMinutes: 5)],
            protectedPaths: ["tests/**"]
        )
        let hooks = try #require(AgentRuntime.hookSettings(checks: full, url: url))
        #expect(hooks["PreToolUse"]?.array?.first?["matcher"] == .string("Edit|MultiEdit|Write|NotebookEdit"))
        #expect(hooks["PreToolUse"]?.array?.first?["hooks"]?.array?.first?["type"] == .string("http"))
        #expect(hooks["PostToolUse"]?.array?.first?["hooks"]?.array?.first?["timeout"] == .number(630))
        #expect(hooks["Stop"]?.array?.first?["hooks"]?.array?.first?["url"] == .string(url.absoluteString))
        #expect(hooks["Stop"]?.array?.first?["hooks"]?.array?.first?["timeout"] == .number(930))

        let testsOnly = AgentRuntime.hookSettings(checks: ChecksConfig(checks: [CheckDefinition(name: "test", kind: .test, command: "t")]), url: url)
        #expect(testsOnly?["PreToolUse"] == nil)
        #expect(testsOnly?["PostToolUse"] == nil)
        #expect(testsOnly?["Stop"] != nil)
        #expect(AgentRuntime.hookSettings(checks: ChecksConfig(), url: url) == nil)

        let launch = ClaudeLaunch(
            executable: URL(filePath: "/bin/claude"), worktree: URL(filePath: "/tmp"), session: .new("s"), model: "sonnet",
            systemPrompt: "", environment: [:], hooks: hooks
        )
        let settings = try #require(JSONValue.parse(launch.settings))
        #expect(settings["disableBundledSkills"] == .bool(true))
        #expect(settings["hooks"] == hooks)
    }
}

@Suite struct CheckRunnerTests {
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "check-runner-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func reportsPassesFailuresAndTimeouts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CheckRunner(environment: ProcessInfo.processInfo.environment, killGracePeriod: .milliseconds(100), minute: .milliseconds(300))
        let results = await runner.run([
            CheckDefinition(name: "format", kind: .format, command: "echo formatted in \"$ENSEMBLE_AGENT\""),
            CheckDefinition(name: "unit tests", kind: .test, command: "echo '2 passed, 1 failed'; echo 'AssertionError: refund total' >&2; exit 3"),
            CheckDefinition(name: "slow", kind: .lint, command: "sleep 5", timeoutMinutes: 1),
        ], in: directory, variables: ["ENSEMBLE_AGENT": "Dev 1"], logDirectory: directory.appending(path: "logs"))

        #expect(results.map(\.status) == [.passed, .failed, .timedOut])
        #expect(results[0].output == "formatted in Dev 1")
        #expect(results[1].exitCode == 3)
        #expect(results[1].output.contains("AssertionError: refund total"))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "logs/unit-tests.log").path))

        let report = CheckReport(agentName: "Dev 1", results: results)
        #expect(!report.passed)
        #expect(report.summary == "Dev 1: unit tests failed (exit 3); slow timed out")
        #expect(report.failureDetails().contains("Command: `echo '2 passed, 1 failed'"))
    }
}

@Suite struct CheckDetectorTests {
    func repository(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "detect-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (path, contents) in files {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func suggestsChecksForANodeProject() throws {
        let root = try repository([
            "package.json": #"{"scripts":{"test":"vitest run","lint":"eslint .","format:check":"prettier -c ."}}"#,
            "pnpm-lock.yaml": "",
            "tsconfig.json": "{}",
            "src/refunds.test.ts": "",
            "src/refunds.ts": "",
            "node_modules/x/package.json": "{}",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let suggestions = CheckDetector.suggest(repository: root)
        #expect(suggestions.checks.map(\.command) == ["pnpm format:check", "pnpm lint", "npx tsc --noEmit", "pnpm test"])
        #expect(suggestions.checks.map(\.kind) == [.format, .lint, .typecheck, .test])
        #expect(suggestions.checks[0].onEdit)
        #expect(suggestions.protectedPaths == ["*.test.*"])
        #expect(suggestions.hasTestCheck)
    }

    @Test func suggestsChecksForAPythonProjectUsingUV() throws {
        let root = try repository([
            "pyproject.toml": "[project]\nname = \"shop\"\n\n[tool.ruff]\nline-length = 100\n",
            "uv.lock": "",
            "tests/test_refunds.py": "",
            "shop/refunds.py": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let suggestions = CheckDetector.suggest(repository: root)
        #expect(suggestions.checks.map(\.command) == ["uv run ruff format --check .", "uv run ruff check .", "uv run pytest -q"])
        #expect(suggestions.protectedPaths == ["tests/**"])
    }

    @Test func findsNoTestCheckWhenThereIsNothingToRun() throws {
        let root = try repository(["README.md": "hello"])
        defer { try? FileManager.default.removeItem(at: root) }
        let suggestions = CheckDetector.suggest(repository: root)
        #expect(suggestions.checks.isEmpty)
        #expect(!suggestions.hasTestCheck)
    }
}

@MainActor
@Suite(.serialized) struct CheckSetupNoticeTests {
    @Test func suggestsChecksOnceForAProjectWithoutThem() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        #expect(try CheckSetupNotice.postIfNeeded(for: harness.project, config: ProjectConfig(), database: harness.database) == nil)

        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        try #"{"scripts":{"lint":"eslint ."}}"#.write(to: harness.repo.root.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let config = ProjectConfigLoader.load(repository: harness.repo.root)
        let notice = try #require(try CheckSetupNotice.postIfNeeded(for: harness.project, config: config, database: harness.database))
        #expect(notice.kind == .notice)
        #expect(notice.body.contains("• lint: npm run lint"))
        #expect(notice.body.contains("There is no test command among them"))
        _ = try harness.database.resolveInboxItem(id: try #require(notice.id))
        #expect(try CheckSetupNotice.postIfNeeded(for: harness.project, config: config, database: harness.database) == nil)

        var withChecks = config
        withChecks.checks = ChecksConfig(checks: [CheckDefinition(name: "lint", kind: .lint, command: "npm run lint")])
        #expect(try CheckSetupNotice.postIfNeeded(for: harness.project, config: withChecks, database: harness.database) == nil)
    }
}
