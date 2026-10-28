import Foundation

extension AgentWorkflowDriver {
    nonisolated static let needsDecision = "needs_decision"

    public func runGateStep(_ context: StepContext) async throws -> StepResult {
        let git = try requireGit()
        let runId = try requireRunID(context.run)
        let policy = ProjectConfigLoader.load(repository: context.project.url).review
        let builders = try runtime.runSessions(runId: runId, projectId: context.project.id ?? -1)
            .filter { !$0.agent.readOnly && $0.agent.worktreeURL != nil && $0.agent.archivedAt == nil }
        let evidence = try runtime.database.evidence(runId: runId)
        var findings: [GateFinding] = []
        for session in builders {
            try Task.checkCancellation()
            findings += await gateFindings(for: session.agent, policy: policy, labels: context.inputs.labels, evidence: evidence, git: git)
        }
        let criteria = criteriaGate(context)
        let fresh = GateReport.undecided(findings, after: context.inputs.previousOutputs, stepId: context.step.id)
        let report = GateReport(findings: fresh + criteria.findings, criteria: criteria.results)
        let outcome = report.passed ? StepOutcome.passed : Self.needsDecision
        return StepResult(outcome: outcome, output: StepOutput(summary: report.summary, gates: report))
    }

    func gateFindings(for agent: Agent, policy: ReviewPolicy, labels: [String], evidence: [Evidence], git: GitClient) async -> [GateFinding] {
        guard let worktree = agent.worktreeURL, let base = agent.baseBranch else { return [] }
        let start = await ProtectedChanges.mergeBase(of: base, in: worktree, git: git)
        let numstat = (try? await git.run(["diff", "--numstat", start], in: worktree)) ?? ""
        let changes = numstat.split(separator: "\n").compactMap { row -> (path: String, lines: Int)? in
            let columns = row.split(separator: "\t", maxSplits: 2).map(String.init)
            guard columns.count == 3 else { return nil }
            return (columns[2], (Int(columns[0]) ?? 0) + (Int(columns[1]) ?? 0))
        }.filter { !GeneratedFiles.isGenerated($0.path) }
        guard !changes.isEmpty else { return [] }

        var findings: [GateFinding] = []
        let lines = changes.reduce(0) { $0 + $1.lines }
        if lines > policy.sizeGuard.maxLines || changes.count > policy.sizeGuard.maxFiles {
            findings.append(GateFinding(
                kind: .size, severity: .blocking, title: "Large change: \(lines) lines in \(changes.count) files",
                detail: "That’s more than the \(policy.sizeGuard.maxLines)-line, \(policy.sizeGuard.maxFiles)-file limit for one reviewable unit. Send it back to be split into smaller tasks, or continue if it has to land together.",
                agentName: agent.name
            ))
        }

        let diff = ScannedDiff.parse((try? await git.run(["diff", "-U0", "--no-color", "--no-ext-diff", start], in: worktree)) ?? "")
        if policy.gates.secrets {
            findings += SecretScanner.scan(diff.added, agentName: agent.name)
        }
        if policy.gates.dependencies {
            findings += await dependencyFindings(changes.map(\.path), start: start, worktree: worktree, agent: agent, git: git)
        }
        let tracked = ((try? await git.run(["ls-files"], in: worktree)) ?? "").split(separator: "\n").map(String.init)
        findings += DuplicationScanner.scan(diff, worktree: worktree, trackedFiles: tracked, limit: policy.gates.maxDuplicateLines, agentName: agent.name)
        findings += ComplexityScanner.scan(diff, limit: policy.gates.maxComplexityIncrease, agentName: agent.name)

        let mine = evidence.filter { $0.agentId == agent.id }
        if let ui = changes.first(where: { change in policy.evidence.uiPaths.contains { PathGlob($0).matches(change.path) } }),
           !mine.contains(where: { [.screenshot, .recording].contains($0.kind) }) {
            findings.append(GateFinding(
                kind: .evidence, severity: .warning, title: "UI change without a screenshot",
                detail: "\(ui.path) changes what people see, but \(displayName(of: agent)) attached no screenshot or recording. Ask for one, or check the UI yourself.",
                file: ui.path, agentName: agent.name
            ))
        }
        let lowered = Set(labels.map { $0.lowercased() })
        if policy.evidence.performanceLabels.contains(where: { lowered.contains($0.lowercased()) }), !mine.contains(where: { $0.kind == .benchmark }) {
            findings.append(GateFinding(
                kind: .evidence, severity: .warning, title: "Performance work without a benchmark",
                detail: "The task is labelled as performance work, but \(displayName(of: agent)) attached no benchmark showing the before and after.",
                agentName: agent.name
            ))
        }
        return findings
    }

    private func dependencyFindings(_ paths: [String], start: String, worktree: URL, agent: Agent, git: GitClient) async -> [GateFinding] {
        var findings: [GateFinding] = []
        for path in paths where DependencyScanner.isManifest(path) {
            guard let head = try? String(contentsOf: worktree.appending(path: path), encoding: .utf8) else { continue }
            let base = try? await git.run(["show", "\(start):\(path)"], in: worktree)
            for dependency in DependencyScanner.newDependencies(file: path, base: base, head: head) {
                let exists = await packageRegistry.exists(dependency.name, in: dependency.ecosystem)
                let (title, detail): (String, String) = switch exists {
                case false?:
                    ("Unknown package: \(dependency.name)", "\(dependency.name) doesn’t exist on \(dependency.ecosystem.registryName). It may be a made-up name that someone could register later. Send it back to remove it.")
                case nil:
                    ("New dependency: \(dependency.name)", "Ensemble couldn’t reach \(dependency.ecosystem.registryName) to confirm \(dependency.name) exists. Check it before approving.")
                case true?:
                    ("New dependency: \(dependency.name)", "\(displayName(of: agent)) added \(dependency.name) from \(dependency.ecosystem.registryName). Approve it, or send it back to do without.")
                }
                findings.append(GateFinding(kind: .dependency, severity: .blocking, title: title, detail: detail, file: path, agentName: agent.name))
            }
        }
        return findings
    }
}
