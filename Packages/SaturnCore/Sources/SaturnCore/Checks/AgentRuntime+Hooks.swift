import Foundation

struct AgentHookState {
    var greenFingerprint: String?
    var stopBlocks = 0
}

extension AgentWorkflowDriver: AgentHookSink {
    public func handleHook(_ input: JSONValue, from agentID: Int64) async -> JSONValue {
        await runtime.handleHook(input, agentID: agentID)
    }
}

extension AgentRuntime {
    nonisolated static let editingToolMatcher = "Edit|MultiEdit|Write|NotebookEdit"
    nonisolated static let maxStopBlocks = 2

    nonisolated static func hookSettings(checks: ChecksConfig?, policy: PermissionPolicy? = nil, url: URL) -> JSONValue? {
        let hook = { (timeout: Int) -> JSONValue in
            .object(["type": .string("http"), "url": .string(url.absoluteString), "timeout": .number(Double(timeout))])
        }
        var events: [String: JSONValue] = [:]
        var guarded: [String] = []
        if checks?.protectedPaths.isEmpty == false { guarded += editingToolMatcher.split(separator: "|").map(String.init) }
        if let policy {
            if policy.hasBash { guarded.append("Bash") }
            if policy.level(.editFiles) != .allow { guarded += AgentPermissions.fileWritingTools }
            if policy.level(.network) == .ask { guarded += AgentPermissions.webTools }
        }
        let matcher = guarded.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !matcher.isEmpty {
            events["PreToolUse"] = .array([.object(["matcher": .string(matcher.joined(separator: "|")), "hooks": .array([hook(30)])])])
        }
        guard let checks else { return events.isEmpty ? nil : .object(events) }
        if !checks.editChecks.isEmpty {
            let timeout = min(3600, checks.editChecks.reduce(0) { $0 + $1.timeoutMinutes * 60 } + 30)
            events["PostToolUse"] = .array([.object(["matcher": .string(editingToolMatcher), "hooks": .array([hook(timeout)])])])
        }
        if !checks.checks.isEmpty {
            let timeout = min(3600, checks.checks.reduce(0) { $0 + $1.timeoutMinutes * 60 } + 30)
            events["Stop"] = .array([.object(["hooks": .array([hook(timeout)])])])
        }
        return events.isEmpty ? nil : .object(events)
    }

    nonisolated static func checksGuide(_ checks: ChecksConfig) -> String? {
        var lines: [String] = []
        if !checks.checks.isEmpty {
            lines.append("Saturn runs these checks on your worktree before your work reaches review, and again when you end your turn: "
                + checks.checks.map { "\($0.name) (`\($0.command)`)" }.joined(separator: ", ") + ". Make them pass before you finish.")
        }
        if !checks.protectedPaths.isEmpty {
            lines.append("Existing files matching " + checks.protectedPaths.map { "`\($0)`" }.joined(separator: ", ")
                + " are protected: Saturn blocks edits to them. Add new test files instead of changing existing tests, and never disable or skip a test to make checks pass.")
        }
        return lines.isEmpty ? nil : "# Checks\n" + lines.joined(separator: "\n")
    }

    func handleHook(_ input: JSONValue, agentID: Int64) async -> JSONValue {
        guard let agent = try? database.agent(id: agentID), let project = try? database.project(id: agent.projectId) else { return .object([:]) }
        let config = ProjectConfigLoader.load(repository: project.filesRoot)
        if input["hook_event_name"]?.string == "PreToolUse" {
            if !agent.readOnly, let worktree = agent.worktreeURL, let checks = config.checks {
                let protected = await protectFiles(input, agent: agent, worktree: worktree, checks: checks)
                if protected != .object([:]) { return protected }
            }
            let policy = PermissionPolicy(profile: config.permissions.resolve(for: agent.kind, readOnly: agent.readOnly), readOnly: agent.readOnly)
            let directory = (agent.worktreeURL ?? project.url).path
            return (try? permissionDecision(input, agent: agent, policy: policy, directory: directory)) ?? .object([:])
        }
        guard !agent.readOnly, let worktree = agent.worktreeURL, let checks = config.checks else { return .object([:]) }
        switch input["hook_event_name"]?.string {
        case "PostToolUse":
            return await checkAfterEdit(agent: agent, checks: checks)
        case "Stop":
            return await checkBeforeStopping(input, agent: agent, worktree: worktree, checks: checks)
        default:
            return .object([:])
        }
    }

    private func protectFiles(_ input: JSONValue, agent: Agent, worktree: URL, checks: ChecksConfig) async -> JSONValue {
        guard let path = input["tool_input"]?["file_path"]?.string ?? input["tool_input"]?["notebook_path"]?.string,
              let relative = Self.relativePath(path, in: worktree),
              let pattern = checks.protectedPaths.first(where: { PathGlob($0).matches(relative) }),
              let project = try? database.project(id: agent.projectId), let git = projectGit(project), let base = agent.baseBranch else { return .object([:]) }
        let start = await ProtectedChanges.mergeBase(of: base, in: worktree, git: git)
        guard (try? await git.run(["cat-file", "-e", "\(start):\(relative)"], in: worktree)) != nil else { return .object([:]) }
        let reason = "\(relative) is a protected file (it matches “\(pattern)”), so Saturn blocked this edit. "
            + "Existing tests are read-only: add a new test file instead, or explain in your summary why this test is wrong."
        return .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string("deny"),
            "permissionDecisionReason": .string(reason),
        ])])
    }

    private func checkAfterEdit(agent: Agent, checks: ChecksConfig) async -> JSONValue {
        guard !checks.editChecks.isEmpty else { return .object([:]) }
        let report = CheckReport(agentName: agent.name, results: await runChecks(checks.editChecks, for: agent, label: "after-edit"))
        guard !report.passed else { return .object([:]) }
        return .object([
            "decision": .string("block"),
            "reason": .string("Saturn ran the edit checks after your change and they failed:\n\n" + report.failureDetails(outputLines: 30)),
        ])
    }

    private func checkBeforeStopping(_ input: JSONValue, agent: Agent, worktree: URL, checks: ChecksConfig) async -> JSONValue {
        guard let id = agent.id, !checks.checks.isEmpty, let project = try? database.project(id: agent.projectId),
              let git = projectGit(project), let base = agent.baseBranch else { return .object([:]) }
        var state = hookStates[id] ?? AgentHookState()
        if input["stop_hook_active"]?.bool != true { state.stopBlocks = 0 }
        defer { hookStates[id] = state }

        let start = await ProtectedChanges.mergeBase(of: base, in: worktree, git: git)
        let head = (try? await git.run(["rev-parse", "HEAD"], in: worktree))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = (try? await git.run(["status", "--porcelain"], in: worktree)) ?? ""
        if head == start && status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([:]) }
        let fingerprint = head + "\n" + status
        if state.greenFingerprint == fingerprint { return .object([:]) }
        guard state.stopBlocks < Self.maxStopBlocks else { return .object([:]) }

        let report = CheckReport(agentName: agent.name, results: await runChecks(checks.checks, for: agent, label: "before-stop"))
        if report.passed {
            state.greenFingerprint = fingerprint
            return .object([:])
        }
        state.stopBlocks += 1
        return .object([
            "decision": .string("block"),
            "reason": .string("Don’t finish yet: the project’s checks fail on your worktree.\n\n" + report.failureDetails(outputLines: 30)
                + "\n\nFix the code so they pass (don’t edit or skip existing tests), commit, then finish."),
        ])
    }

    nonisolated static func relativePath(_ path: String, in worktree: URL) -> String? {
        let root = realPath(of: worktree) + "/"
        let absolute = path.hasPrefix("/") ? URL(filePath: path) : worktree.appending(path: path)
        let resolved = realPath(of: absolute.deletingLastPathComponent()) + "/" + absolute.lastPathComponent
        guard resolved.hasPrefix(root) else { return nil }
        return String(resolved.dropFirst(root.count))
    }
}
