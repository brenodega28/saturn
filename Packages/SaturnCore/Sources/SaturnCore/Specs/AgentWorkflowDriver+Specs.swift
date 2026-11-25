import Foundation

extension AgentWorkflowDriver {
    var specStore: SpecStore { SpecStore(paths: runtime.paths, database: runtime.database) }

    func draftSpec(_ request: SpecDraftRequest, from agent: Agent) throws -> SpecDocument {
        guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can draft its spec.") }
        let store = specStore
        let url = store.draftURL(projectId: agent.projectId, taskId: taskId)
        var document = SpecDocument(title: request.title, owner: request.owner ?? "")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            if let existing = try? SpecDocument(markdown: text) {
                if existing.status == .done {
                    throw HandoffError.notAllowed("This request’s spec “\(existing.title)” is done. Start a new request for a new spec.")
                }
                if try runtime.database.runs(taskId: taskId).contains(where: \.isActive) {
                    throw HandoffError.notAllowed("A run for this request is going and its spec is committed on the run branch. Use message_agent to change the work instead.")
                }
                document = existing
                document.version = existing.version + 1
                if existing.status == .rejected { document.status = .draft }
            }
        }
        document.title = request.title
        document.workers = request.workers
        if let workflow = request.workflow { document.workflow = workflow }
        if let owner = request.owner { document.owner = owner }
        document.summary = request.summary
        document.interfaces = request.interfaces
        document.outOfScope = request.outOfScope
        document.acceptanceCriteria = request.acceptanceCriteria.map { text in
            SpecCriterion(text: text, checked: document.acceptanceCriteria.contains { $0.checked && SpecCriteria.normalized($0.text) == SpecCriteria.normalized(text) })
        }
        document.verification = request.verification
        try store.write(document, to: url)
        return document
    }

    func postSpecDraft(_ document: SpecDocument, from agent: Agent) async throws -> String {
        guard let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can draft its spec.") }
        let review = await specReviews?.specDrafted(projectId: agent.projectId, taskId: taskId)
            ?? SpecReviewStatus(reason: "Live review in Lavish isn’t set up in this Saturn, so the spec opens read-only.")
        let info = SpecDraftInfo(version: document.version, criteria: document.acceptanceCriteria.count, review: review)
        try runtime.database.insertSpecDraft(projectId: agent.projectId, taskId: taskId, title: document.title, info: info)
        return specDraftReply(document, review: review, agent: agent)
    }

    func specDraftReply(_ document: SpecDocument, review: SpecReviewStatus, agent: Agent) -> String {
        let folder = (try? runtime.database.project(id: agent.projectId)).flatMap { $0 }.map { ProjectConfigLoader.loadSpecs(repository: $0.filesRoot).folder } ?? SpecsConfig.defaultFolder
        let count = document.acceptanceCriteria.count
        let saved = "Saved spec v\(document.version) “\(document.title)” with \(count) acceptance criteri\(count == 1 ? "on" : "a") and \(document.version == 1 ? "rendered" : "re-rendered") its review page. The chat shows the user a spec card to open, approve or ask for changes."
        let page = review.url != nil
            ? "The page is open in Lavish. The user annotates it; their notes arrive as chat messages tagged as spec feedback. Revise with this tool and answer on the page with `\(HandoffTool.replySpec.qualifiedName)`."
            : "The Lavish review page did not open: \(review.reason ?? "unknown reason") The user can only read the spec, so ask for feedback in the chat and revise with this tool."
        let start = "When the user approves the spec or starts a run you propose, Saturn commits it as \(folder)/\(Slug.make(document.title).nilIfEmpty ?? "spec").md on the run branch."
        return [saved, page, start].joined(separator: " ")
    }

    func replySpec(_ text: String, from agent: Agent) async throws -> String {
        guard agent.kind == .lead, let taskId = agent.taskId else { throw HandoffError.notAllowed("Only a request’s lead can reply on its spec review page.") }
        guard let reviews = specReviews else {
            throw HandoffError.notAllowed("No Lavish review is open for this request’s spec, so there’s nothing to reply on. Answer in the chat instead.")
        }
        try await reviews.replySpec(taskId: taskId, text: text)
        return "Your reply shows on the spec review page and the notes you received are marked done."
    }

    public func rejectSpec(projectId: Int64, taskId: Int64) throws {
        let store = specStore
        let url = store.draftURL(projectId: projectId, taskId: taskId)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var document = try SpecDocument(markdown: text)
        document.status = .rejected
        try store.write(document, to: url)
    }

    func rejectionNote(projectId: Int64, taskId: Int64) -> String? {
        let url = specStore.draftURL(projectId: projectId, taskId: taskId)
        guard let text = try? String(contentsOf: url, encoding: .utf8), let document = try? SpecDocument(markdown: text), document.status == .rejected else { return nil }
        return "Saturn note (not written by the user): the user rejected spec v\(document.version) “\(document.title)”. This message says why. Write the next version with `\(HandoffTool.draftSpec.qualifiedName)` before proposing a run."
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
            The user approved this spec. Saturn committed it as `\(spec.link.path)` on the run branch. Its acceptance criteria are fixed: keep them as they are. Refine the tasks freely, and add interfaces or out-of-scope notes in your plan’s spec only when the work needs them.\(Self.workersGuide(spec.document.workers))

            \(spec.document.planSpec.markdown)
            """
    }

    static func workersGuide(_ workers: [SpecWorker]) -> String {
        guard !workers.isEmpty else { return "" }
        let builders = workers.filter { $0.kind == .builder }.count
        return " The approval covers the workers it lists (\(builders) builder\(builders == 1 ? "" : "s")) and its workflow: a plan within them goes straight to build, so don’t ask the user to approve the plan or the agent count again. A plan with more builders stops for the user’s approval."
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
        let manager = WorktreeManager(project: project, git: git)
        let worktree = try manager.path(forAgent: "spec-run-\(runId)")
        if (try? await git.fileSystem.fileExists(worktree)) == true {
            _ = try? await git.run(["worktree", "remove", "--force", worktree.path], in: project.url)
        }
        let base = try await git.baseBranch(of: project.url) ?? "HEAD"
        try await manager.ensureExcluded()
        try await git.fileSystem.createDirectory(manager.crewDirectory)
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
        try await git.fileSystem.createDirectory(file.deletingLastPathComponent())
        try await git.fileSystem.writeText(document.markdown, to: file)
        try await git.run(["add", "--", path], in: worktree)
        let staged = try await git.execute(["diff", "--cached", "--quiet", "--", path], in: worktree)
        guard !staged.succeeded else { return }
        try await git.run(["-c", "user.name=Saturn", "-c", "user.email=saturn@localhost", "commit", "-m", message, "--", path], in: worktree)
    }

    func completeSpec(for run: Run, in worktree: URL, git: GitClient) async throws {
        guard let runId = run.id, let spec = specStore.runSpec(runId: runId) else { return }
        let file = worktree.appending(path: spec.link.path)
        let committed = (try? await git.fileSystem.readText(file)).flatMap { $0 }.flatMap { try? SpecDocument(markdown: $0) } ?? spec.document
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
    }
}

extension LeadChat {
    func attachSpec(to run: Run, taskId: Int64, document: SpecDocument, project: Project, config: ProjectConfig) throws {
        guard let runId = run.id, let projectId = project.id else { return }
        let store = SpecStore(paths: runtime.paths, database: database)
        var started = document
        started.status = .inProgress
        if !started.linkedRuns.contains(runId) { started.linkedRuns.append(runId) }
        let path = SpecStore.availablePath(
            title: started.title, folder: config.specs.folder, repository: project.filesRoot,
            taken: store.pathsInUse(projectId: projectId, excludingTask: taskId)
        )
        let url = store.draftURL(projectId: projectId, taskId: taskId)
        try store.write(started, to: url)
        try store.save(RunSpecLink(projectId: projectId, taskId: taskId, path: path, branch: RunSpecLink.branch(runId: runId)), runId: runId)
    }

    func pendingSpec(taskId: Int64, projectId: Int64) throws -> SpecDocument? {
        let store = SpecStore(paths: runtime.paths, database: database)
        guard FileManager.default.fileExists(atPath: store.draftURL(projectId: projectId, taskId: taskId).path) else { return nil }
        guard let document = try store.draft(projectId: projectId, taskId: taskId), document.status != .done else { return nil }
        return document
    }
}
