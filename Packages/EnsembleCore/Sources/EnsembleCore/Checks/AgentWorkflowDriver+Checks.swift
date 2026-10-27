import Foundation
import GRDB

extension AgentWorkflowDriver {
    nonisolated static let reproductionPrefix = "Reproduce:"
    nonisolated static let testChangeTag = "test-change"
    nonisolated static let freshSessionAfterFailedCorrections = 2

    public func runCheckStep(_ context: StepContext) async throws -> StepResult {
        let git = try requireGit()
        let runId = try requireRunID(context.run)
        let config = ProjectConfigLoader.load(repository: context.project.url)
        guard let checksConfig = config.checks, case let checks = checksConfig.checks(named: context.step.checks), !checks.isEmpty else {
            throw WorkflowDriverError.notReady("There are no checks to run. Add them to \(ProjectConfig.directoryName)/\(ChecksConfig.fileName).")
        }
        let builders = try runtime.runSessions(runId: runId, projectId: context.project.id ?? -1)
            .filter { !$0.agent.readOnly && $0.agent.worktreeURL != nil && $0.agent.archivedAt == nil }
        guard !builders.isEmpty else {
            return StepResult(outcome: StepOutcome.passed, output: StepOutput(summary: "No branches to check."))
        }

        try await ensureServer()
        let maxRounds = max(1, context.step.maxRounds ?? checksConfig.maxRounds)
        let startCosts = Dictionary(uniqueKeysWithValues: builders.map { ($0.id, $0.agent.costUSD) })
        var latest: [Int64: CheckReport] = [:]
        var pending = builders
        var round = 1
        while true {
            for session in pending {
                try Task.checkCancellation()
                await pinProtectedChanges(of: session, protectedPaths: checksConfig.protectedPaths, runId: runId, git: git)
                var report = CheckReport(
                    agentName: session.agent.name, branch: session.agent.branch, round: round,
                    results: await runtime.runChecks(checks, for: session.agent, label: "\(context.step.id)-\(context.runStepID)-round-\(round)")
                )
                if context.step.testFirst {
                    report.notes += await verifyReproduction(of: session, checks: checks.filter { $0.kind == .test }, git: git, label: "\(context.step.id)-\(context.runStepID)-round-\(round)")
                }
                latest[session.id] = report
            }
            pending = pending.filter { latest[$0.id]?.passed == false }
            for session in builders where latest[session.id]?.passed == true {
                failedCorrections[session.id] = nil
            }
            if pending.isEmpty { break }
            guard round < maxRounds else {
                let failing = pending.compactMap { latest[$0.id] }
                throw WorkflowDriverError.checksFailed(rounds: round, details: failing.map { "## \($0.summary)\n\n\($0.failureDetails(outputLines: 20))" }.joined(separator: "\n\n"))
            }
            let activeIDs = pending.map(\.id)
            try await withTaskCancellationHandler {
                for session in pending {
                    guard let report = latest[session.id] else { continue }
                    let fresh = (failedCorrections[session.id] ?? 0) >= Self.freshSessionAfterFailedCorrections
                    let earlierSummary = results[session.id] ?? lastAssistantText(session)
                    if fresh { session.startNewSession() }
                    clearHandoffs(session.id)
                    session.send(correctionMessage(report, round: round, maxRounds: maxRounds, fresh: fresh, earlierSummary: earlierSummary, context: context))
                }
                for session in pending {
                    try await follow(session, expected: .result)
                    failedCorrections[session.id, default: 0] += 1
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.stopAgents(activeIDs) }
            }
            round += 1
        }

        let reports = builders.compactMap { latest[$0.id] }
        let cost = builders.reduce(0) { $0 + $1.agent.costUSD - (startCosts[$1.id] ?? 0) }
        let heads = await branchHeads(of: builders, in: context.project, git: git)
        let summary = round == 1
            ? "All \(checks.count) checks passed on \(builders.count) branch\(builders.count == 1 ? "" : "es")."
            : "All checks passed after \(round) rounds."
        return StepResult(outcome: StepOutcome.passed, output: StepOutput(summary: summary, branchHeads: heads, checks: reports), costUSD: cost)
    }

    func correctionMessage(_ report: CheckReport, round: Int, maxRounds: Int, fresh: Bool, earlierSummary: String, context: StepContext) -> String {
        var parts = ["# Checks failed (round \(round) of \(maxRounds))"]
        if fresh {
            parts.append("Your previous session was closed because earlier fixes didn’t make the checks pass. Start fresh: look at the failures below with new eyes instead of repeating the last approach.")
            parts.append("## Your task\n\(context.inputs.taskTitle)" + (context.inputs.taskBody.isEmpty ? "" : "\n\n\(context.inputs.taskBody)"))
            if !earlierSummary.isEmpty { parts.append("## What you reported before\n\(earlierSummary)") }
            parts.append("Your branch `\(report.branch ?? "")` already has your commits; read them with `git log` and `git diff`.")
        }
        parts.append("Ensemble ran the project’s checks on your worktree and these failed:")
        parts.append(report.failureDetails())
        parts.append("Fix the code so the checks pass. Don’t edit or disable existing tests to make them pass. Commit, then call `\(HandoffTool.submitResult.qualifiedName)` with what you changed and end your turn.")
        return parts.joined(separator: "\n\n")
    }

    func pinProtectedChanges(of session: AgentSession, protectedPaths: [String], runId: Int64, git: GitClient) async {
        guard let worktree = session.agent.worktreeURL, let base = session.agent.baseBranch else { return }
        let changes = await ProtectedChanges.find(in: worktree, base: base, protectedPaths: protectedPaths, git: git)
        guard !changes.isEmpty else { return }
        let agentName = session.agent.name
        let agentID = session.id
        let now = Date()
        try? await runtime.database.writer.write { db in
            let existing = try Pin.filter(Column("runId") == runId).fetchAll(db)
            for change in changes where !existing.contains(where: { $0.file == change.path && $0.tags.contains(Self.testChangeTag) && $0.status == .open }) {
                var pin = Pin(
                    runId: runId, agentId: agentID, file: change.path, startLine: change.line, endLine: change.line,
                    side: change.deleted ? .old : .new,
                    title: change.deleted ? "Test deleted: \(change.path)" : "Test changed: \(change.path)",
                    tags: [Self.testChangeTag],
                    explanation: "\(agentName) \(change.deleted ? "deleted" : "changed") an existing protected file (it matches “\(change.pattern)”). Check that the test still verifies what it should and wasn’t weakened to make the checks pass.",
                    createdAt: now, updatedAt: now
                )
                try pin.insert(db)
            }
        }
    }

    func verifyReproduction(of session: AgentSession, checks: [CheckDefinition], git: GitClient, label: String) async -> [String] {
        guard let worktree = session.agent.worktreeURL, let base = session.agent.baseBranch, !checks.isEmpty,
              let project = try? runtime.database.project(id: session.agent.projectId) else { return [] }
        let start = await ProtectedChanges.mergeBase(of: base, in: worktree, git: git)
        guard let commit = await ProtectedChanges.reproductionCommit(prefix: Self.reproductionPrefix, since: start, in: worktree, git: git) else {
            return ["No reproduction commit: this step is test-first, so commit a failing test on its own with a message starting with “\(Self.reproductionPrefix)” before the fix."]
        }
        let checkout = runtime.paths.agentDirectory(session.id).appending(path: "reproduction", directoryHint: .isDirectory)
        await removeWorktree(at: checkout, repository: project.url, git: git)
        let notes: [String]
        do {
            try await git.run(["worktree", "add", "--detach", checkout.path, commit], in: project.url)
            if runtime.needsSetup(projectId: session.agent.projectId) {
                try await runtime.runSetupScript(WorktreePreparation(
                    projectId: session.agent.projectId, agentID: session.id, agentName: session.agent.name, worktree: checkout,
                    port: session.agent.port, logDirectory: runtime.paths.agentDirectory(session.id).appending(path: "reproduction-setup")
                ))
            }
            let results = await runtime.runChecks(checks, for: session.agent, in: checkout, label: label + "-reproduction")
            notes = results.allSatisfy(\.passed)
                ? ["The reproduction commit \(commit.prefix(7)) already passes \(checks.map(\.name).joined(separator: ", ")), so its test doesn’t reproduce the problem. Make the test fail without the fix."]
                : []
        } catch {
            notes = ["Couldn’t check out the reproduction commit \(commit.prefix(7)): \(error.localizedDescription)"]
        }
        await removeWorktree(at: checkout, repository: project.url, git: git)
        return notes
    }

    private func removeWorktree(at path: URL, repository: URL, git: GitClient) async {
        _ = try? await git.run(["worktree", "remove", "--force", path.path], in: repository)
        try? FileManager.default.removeItem(at: path)
        _ = try? await git.run(["worktree", "prune"], in: repository)
    }
}
