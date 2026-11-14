import Foundation

extension AgentWorkflowDriver {
    var specStore: SpecStore { SpecStore(paths: runtime.paths) }

    func draftSpec(_ request: SpecDraftRequest, from agent: Agent) throws -> String {
        guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can draft its spec.") }
        let store = specStore
        let url = store.draftURL(projectId: agent.projectId, taskId: taskId)
        var document = SpecDocument(title: request.title, owner: request.owner ?? "")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            if let edited = store.unseenEdit(of: url) {
                store.markSeen(url)
                throw HandoffError.notAllowed("""
                    The user edited the spec draft since you last saw it, so nothing was written. The file is the source of truth; here it is as it stands now:

                    \(edited)
                    Keep the user’s edits and call `\(HandoffTool.draftSpec.qualifiedName)` again with the complete merged spec.
                    """)
            }
            if let existing = try? SpecDocument(markdown: text) {
                if existing.status == .done {
                    throw HandoffError.notAllowed("This request’s spec “\(existing.title)” is done. Start a new request for a new spec.")
                }
                if try runtime.database.runs(taskId: taskId).contains(where: \.isActive) {
                    throw HandoffError.notAllowed("A run for this request is going and its spec is committed on the run branch. Use message_agent to change the work instead.")
                }
                document = existing
            }
        }
        document.title = request.title
        if let owner = request.owner { document.owner = owner }
        document.summary = request.summary
        document.interfaces = request.interfaces
        document.outOfScope = request.outOfScope
        document.acceptanceCriteria = request.acceptanceCriteria.map { text in
            SpecCriterion(text: text, checked: document.acceptanceCriteria.contains { $0.checked && SpecCriteria.normalized($0.text) == SpecCriteria.normalized(text) })
        }
        document.verification = request.verification
        try store.write(document, to: url)
        store.markSeen(url)

        let folder = (try? runtime.database.project(id: agent.projectId)).flatMap { $0 }.map { ProjectConfigLoader.loadSpecs(repository: $0.url).folder } ?? SpecsConfig.defaultFolder
        let count = document.acceptanceCriteria.count
        return """
            Saved the spec draft “\(document.title)” with \(count) acceptance criteri\(count == 1 ? "on" : "a"). The user sees it in the chat and can open and edit it. That file is the source of truth: if the user edits it, the current text comes with their next message, and you must build on it rather than on what you sent before. When the user starts a run you propose, Ensemble commits it as \(folder)/\(Slug.make(document.title).nilIfEmpty ?? "spec").md on the run branch.
            """
    }

    func specEditNote(projectId: Int64, taskId: Int64) -> String? {
        let store = specStore
        let url = store.draftURL(projectId: projectId, taskId: taskId)
        guard let edited = store.unseenEdit(of: url) else { return nil }
        store.markSeen(url)
        return "Ensemble note (not written by the user): the user edited this request’s spec draft. The file is the source of truth; it now reads:\n\n\(edited)\nBuild on this text when you revise the spec."
    }

    func runSpec(runId: Int64?) -> PlanSpec? {
        guard let runId, let spec = specStore.runSpec(runId: runId) else { return nil }
        return spec.document.planSpec
    }

    func effectiveSpec(_ plan: Plan?, run: Run) -> PlanSpec? {
        guard let file = runSpec(runId: run.id) else { return plan?.spec }
        return file.authoritative(over: plan?.spec)
    }

    func specGuide(for run: Run) -> String? {
        guard let runId = run.id, let spec = specStore.runSpec(runId: runId) else { return nil }
        return """
            ## The user’s spec
            The user approved this spec in the chat. Ensemble committed it as `\(spec.link.path)` on the run branch. Its acceptance criteria are fixed: keep them as they are. Refine the tasks freely, and add interfaces or out-of-scope notes in your plan’s spec only when the work needs them.

            \(spec.document.planSpec.markdown)
            """
    }

    func criteriaGuide(for run: Run) -> String? {
        guard let criteria = runSpec(runId: run.id)?.acceptanceCriteria, !criteria.isEmpty else { return nil }
        return SpecCriteria.prompt(for: criteria)
    }

    func mergedPlan(_ plan: Plan, runId: Int64?) -> Plan {
        guard let file = runSpec(runId: runId) else { return plan }
        var merged = plan
        merged.spec = file.authoritative(over: plan.spec)
        return merged
    }

    func criteriaVerdicts(_ outputs: [PreviousOutput], workflow: WorkflowDefinition?) -> [Verdict] {
        outputs.compactMap { output in
            guard let verdict = output.output.verdict, workflow?.step(output.stepId).map({ $0.type == .agent }) ?? true else { return nil }
            return verdict
        }
    }

    func criteriaGate(_ context: StepContext) -> (findings: [GateFinding], results: [CriterionResult]) {
        guard let criteria = runSpec(runId: context.run.id)?.acceptanceCriteria, !criteria.isEmpty else { return ([], []) }
        let verdicts = criteriaVerdicts(context.inputs.previousOutputs, workflow: workflowSnapshot(context.run))
        return (SpecCriteria.findings(criteria: criteria, verdicts: verdicts), SpecCriteria.report(criteria: criteria, verdicts: verdicts))
    }

    @discardableResult
    func ensureSpecBranch(for run: Run, project: Project, git: GitClient) async throws -> String? {
        guard let runId = run.id, let spec = specStore.runSpec(runId: runId) else { return nil }
        let branch = spec.link.branch
        if let pending = specCommits[runId] {
            try await pending.value
            return branch
        }
        if try await git.hasCommit("refs/heads/\(branch)", in: project.url) { return branch }
        let commit = Task { @MainActor in
            try await self.commitSpec(spec.document, at: spec.link.path, branch: branch, runId: runId, project: project, git: git)
        }
        specCommits[runId] = commit
        defer { specCommits[runId] = nil }
        try await commit.value
        return branch
    }

    private func commitSpec(_ document: SpecDocument, at path: String, branch: String, runId: Int64, project: Project, git: GitClient) async throws {
        let manager = WorktreeManager(repository: project.url, git: git)
        let worktree = try manager.path(forAgent: "spec-run-\(runId)")
        if FileManager.default.fileExists(atPath: worktree.path) {
            _ = try? await git.run(["worktree", "remove", "--force", worktree.path], in: project.url)
        }
        let base = try await git.baseBranch(of: project.url) ?? "HEAD"
        try await manager.ensureExcluded()
        try FileManager.default.createDirectory(at: manager.crewDirectory, withIntermediateDirectories: true)
        try await git.run(["worktree", "add", "-b", branch, worktree.path, base], in: project.url)
        do {
            try await writeAndCommit(document, at: path, in: worktree, message: "Add spec: \(document.title)", git: git)
        } catch {
            _ = try? await git.run(["worktree", "remove", "--force", worktree.path], in: project.url)
            _ = try? await git.run(["branch", "-D", branch], in: project.url)
            throw error
        }
        try await git.run(["worktree", "remove", "--force", worktree.path], in: project.url)
    }

    private func writeAndCommit(_ document: SpecDocument, at path: String, in worktree: URL, message: String, git: GitClient) async throws {
        let file = worktree.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.markdown.write(to: file, atomically: true, encoding: .utf8)
        try await git.run(["add", "--", path], in: worktree)
        let staged = try await git.execute(["diff", "--cached", "--quiet", "--", path], in: worktree)
        guard !staged.succeeded else { return }
        try await git.run(["-c", "user.name=Ensemble", "-c", "user.email=ensemble@localhost", "commit", "-m", message, "--", path], in: worktree)
    }

    func completeSpec(for run: Run, in worktree: URL, git: GitClient) async throws {
        guard let runId = run.id, let spec = specStore.runSpec(runId: runId) else { return }
        let file = worktree.appending(path: spec.link.path)
        let committed = (try? String(contentsOf: file, encoding: .utf8)).flatMap { try? SpecDocument(markdown: $0) } ?? spec.document
        let outputs = try runtime.database.runSteps(runId: runId).compactMap { step -> PreviousOutput? in
            guard step.status == .succeeded, let text = step.output,
                  let output = try? JSONDecoder().decode(StepOutput.self, from: Data(text.utf8)) else { return nil }
            return PreviousOutput(stepId: step.stepId, iteration: step.iteration, outcome: step.outcome, output: output)
        }
        var done = SpecCriteria.ticked(committed, verdicts: criteriaVerdicts(outputs, workflow: workflowSnapshot(run)))
        done.status = .done
        if !done.linkedRuns.contains(runId) { done.linkedRuns.append(runId) }
        try await writeAndCommit(done, at: spec.link.path, in: worktree, message: "Update spec: \(done.title)", git: git)

        var draft = spec.document
        draft.status = .done
        draft.acceptanceCriteria = done.acceptanceCriteria.count == draft.acceptanceCriteria.count ? done.acceptanceCriteria : draft.acceptanceCriteria
        if !draft.linkedRuns.contains(runId) { draft.linkedRuns.append(runId) }
        try specStore.write(draft, to: spec.url)
        specStore.markSeen(spec.url)
    }
}

extension LeadChat {
    func attachSpec(to run: Run, taskId: Int64, document: SpecDocument, project: Project, config: ProjectConfig) throws {
        guard let runId = run.id, let projectId = project.id else { return }
        let store = SpecStore(paths: runtime.paths)
        var started = document
        started.status = .inProgress
        if !started.linkedRuns.contains(runId) { started.linkedRuns.append(runId) }
        let path = SpecStore.availablePath(
            title: started.title, folder: config.specs.folder, repository: project.url,
            taken: store.pathsInUse(projectId: projectId, excludingTask: taskId)
        )
        let url = store.draftURL(projectId: projectId, taskId: taskId)
        try store.write(started, to: url)
        store.markSeen(url)
        try store.save(RunSpecLink(projectId: projectId, taskId: taskId, path: path, branch: RunSpecLink.branch(runId: runId)), runId: runId)
    }

    func pendingSpec(taskId: Int64, projectId: Int64) throws -> SpecDocument? {
        let store = SpecStore(paths: runtime.paths)
        guard FileManager.default.fileExists(atPath: store.draftURL(projectId: projectId, taskId: taskId).path) else { return nil }
        guard let document = try store.draft(projectId: projectId, taskId: taskId), document.status != .done else { return nil }
        return document
    }
}
