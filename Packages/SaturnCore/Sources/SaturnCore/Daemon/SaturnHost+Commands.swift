import Foundation

extension SaturnHost {
    func registerCommands() {
        registerProjectCommands()
        registerChatCommands()
        registerRunCommands()
        registerAgentCommands()
        registerApprovalCommands()
        registerSettingsCommands()
        registerCodeCommands()
        registerRemoteAccessCommands()
    }

    public func perform<C: DaemonCommand>(_ command: C) async throws -> C.Response {
        let result = await router.handle(try CommandCoding.envelope(command))
        return try CommandCoding.response(of: C.self, from: result)
    }

    func handle(_ envelope: CommandEnvelope, origin: ClientOrigin = .local) async -> ResultEnvelope {
        await router.handle(envelope, origin: origin)
    }

    func requireProject(_ id: Int64) throws -> Project {
        guard let project = try database.project(id: id) else { throw CommandFailure.notFound("The project") }
        return project
    }

    func requireChat(_ id: Int64) throws -> Chat {
        guard let chat = try database.task(id: id) else { throw CommandFailure.notFound("The chat") }
        return chat
    }

    func requireRun(_ id: Int64) throws -> Run {
        guard let run = try database.run(id: id) else { throw CommandFailure.notFound("The run") }
        return engine.runs[id] ?? run
    }

    func requireSession(_ id: Int64) throws -> AgentSession {
        guard let agent = try database.agent(id: id), let session = runtime.session(for: agent) else { throw CommandFailure.notFound("The agent") }
        return session
    }

    func requireGit(for project: Project) throws -> GitClient {
        guard let git = git(for: project) else {
            throw CommandFailure(code: .failed, message: "Saturn couldn’t find git on \(identity.name). Install the Xcode Command Line Tools there and check again.")
        }
        return git
    }

    func worktreeManager(for project: Project) async throws -> WorktreeManager {
        if let destination = project.host {
            let client = SSHClient(destination: destination, runner: runner)
            return await WorktreeManager.make(repository: project.url, git: GitClient(ssh: client), fileSystem: SSHFileSystem(client: client))
        }
        return WorktreeManager(repository: project.url, git: try requireGit(for: project))
    }

    private func registerProjectCommands() {
        router.register(ProjectCommands.Open.self) { [unowned self] command in
            guard let git else { throw CommandFailure(code: .failed, message: "Saturn couldn’t find git on \(identity.name). Install the Xcode Command Line Tools there and check again.") }
            let root: URL
            do {
                root = try await git.repositoryRoot(containing: URL(fileURLWithPath: command.path, isDirectory: true))
            } catch is CommandError {
                throw CommandFailure(code: .failed, message: "\(command.path) isn’t inside a git repository. Saturn needs git to give each agent its own worktree.")
            }
            let project = try database.openProject(at: root)
            _ = try? await refresh(project)
            return project
        }
        router.register(ProjectCommands.OpenRemote.self) { [unowned self] command in
            let host = RemoteHost(client: SSHClient(destination: command.host, runner: runner))
            let root = try await host.repositoryRoot(containing: command.path)
            return try database.openRemoteProject(path: root, host: command.host)
        }
        router.register(ProjectCommands.Clone.self) { [unowned self] command in
            let destination = URL(fileURLWithPath: command.destination, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CommandFailure(code: .failed, message: "\(destination.path) already exists. Choose another folder name.")
            }
            guard let git else { throw CommandFailure(code: .failed, message: "Saturn couldn’t find git on \(identity.name).") }
            try await git.clone(command.remote, to: destination)
            return try await perform(ProjectCommands.Open(path: destination.path))
        }
        router.register(ProjectCommands.Close.self) { [unowned self] command in
            try database.closeProject(id: command.projectID)
            return Done()
        }
        router.register(ProjectCommands.Forget.self) { [unowned self] command in
            try database.forgetProject(id: command.projectID)
            return Done()
        }
        router.register(ProjectCommands.Rename.self) { [unowned self] command in
            try database.renameProject(id: command.projectID, to: command.name)
            return Done()
        }
        router.register(ProjectCommands.UpdateSettings.self) { [unowned self] command in
            try database.updateSettings(command.settings, forProject: command.projectID)
            runtime.startQueuedTurns(inProject: command.projectID)
            return Done()
        }
        router.register(ProjectCommands.Refresh.self) { [unowned self] command in
            try await refresh(try requireProject(command.projectID))
        }
        router.register(ProjectCommands.ConfigFiles.self) { [unowned self] command in
            ProjectConfigFiles.collect(in: try requireProject(command.projectID).url)
        }
        router.register(ProjectCommands.CheckHarness.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            return try await runtime.checkHarness(of: project, git: try requireGit(for: project))
        }
        router.register(ProjectCommands.InstallDefaults.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            try ProjectConfigLoader.installDefaults(repository: project.filesRoot)
            return Done()
        }
        router.register(ProjectCommands.CreateWorktree.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            try await worktreeManager(for: project).create(agent: command.agent, slug: command.slug)
            return Done()
        }
        router.register(ProjectCommands.RemoveWorktree.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            let manager = try await worktreeManager(for: project)
            guard let worktree = try await manager.list().first(where: { $0.path.path == command.path || realPath(of: $0.path) == realPath(of: URL(fileURLWithPath: command.path)) }) else {
                throw CommandFailure.notFound("The worktree")
            }
            server?.broadcast(.event(.worktreeRemoving(path: worktree.path.path)))
            try await manager.remove(worktree, force: command.force, deleteBranch: command.deleteBranch)
            return Done()
        }
        router.register(ProjectCommands.DeleteOrphanedDirectory.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            try await worktreeManager(for: project).deleteOrphanedDirectory(URL(fileURLWithPath: command.path, isDirectory: true))
            return Done()
        }
    }

    func refresh(_ project: Project) async throws -> ProjectStatus {
        if project.host == nil, !FileManager.default.fileExists(atPath: project.path) {
            return ProjectStatus(missing: true)
        }
        let manager = try await worktreeManager(for: project)
        let recovery = try await manager.recover()
        let branch = try await requireGit(for: project).currentBranch(in: project.url)
        if project.host == nil {
            if let id = project.id, let claude = runtime.claudeExecutable,
               let plugins = try? await SkillPluginInstaller(claude: claude, runner: runner).projectPlugins(in: project.url) {
                pluginSkillCache[id] = Set(plugins.flatMap(\.skills))
            }
            let config = ProjectConfigLoader.load(repository: project.filesRoot)
            reportMigration(RoleMigration.takeNotices(for: project.filesRoot), in: project)
            _ = try? CheckSetupNotice.postIfNeeded(for: project, config: config, database: database)
        }
        return ProjectStatus(
            branch: branch, worktrees: recovery.worktrees.map(WorktreeInfo.init), pruned: recovery.pruned.map(WorktreeInfo.init),
            orphanedDirectories: recovery.orphanedDirectories.map(\.path)
        )
    }

    private func reportMigration(_ notices: [MigrationNotice], in project: Project) {
        guard let id = project.id, !notices.isEmpty else { return }
        let body = "Roles are now built-in Lead, Builder and Checker agents. Saturn updated this project:\n\n"
            + notices.map { "- \($0.file): \($0.message)" }.joined(separator: "\n")
        _ = try? database.createChatRequest(ChatRequest(
            projectId: id, kind: .notice, title: "\(project.name) moved from roles to agent kinds", body: body, createdAt: .now
        ))
    }

    private func registerChatCommands() {
        router.register(ChatCommands.Create.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            return try await leadChat.createRequest(
                command.text, attachments: command.attachments, in: project, workflow: command.workflow,
                leadModel: command.leadModel, leadEffort: command.leadEffort
            )
        }
        router.register(ChatCommands.CreateEmpty.self) { [unowned self] command in
            let now = Date()
            return try database.insert(Chat(
                projectId: command.projectID, title: command.title, body: command.body, source: .chat,
                status: .incoming, createdAt: now, updatedAt: now
            ))
        }
        router.register(ChatCommands.Send.self) { [unowned self] command in
            let chat = try requireChat(command.chatID)
            try await leadChat.send(command.text, attachments: command.attachments, to: chat, in: try requireProject(chat.projectId))
            return Done()
        }
        router.register(ChatCommands.Close.self) { [unowned self] command in
            let chat = try requireChat(command.chatID)
            let project = try requireProject(chat.projectId)
            return try await leadChat.close(chat, as: command.reason, in: project, git: try requireGit(for: project))
        }
        router.register(ChatCommands.ReviewSpec.self) { [unowned self] command in
            _ = try requireChat(command.chatID)
            return await specReviews.status(taskId: command.chatID)
        }
        router.register(ChatCommands.ApproveSpec.self) { [unowned self] command in
            let chat = try requireChat(command.chatID)
            if chat.isClosed {
                throw CommandFailure(code: .failed, message: "This request is closed. Send a message to reopen it first.")
            }
            let project = try requireProject(chat.projectId)
            guard let runID = try await leadChat.approveSpec(taskId: command.chatID, in: project).id else {
                throw CommandFailure(code: .failed, message: "The run started without an id.")
            }
            return runID
        }
        router.register(ChatCommands.Read.self) { [unowned self] command in
            var request = command.request
            request.daemon = nil
            return try ChatReader(database: database, paths: paths).read(request)
        }
        router.register(ChatCommands.SetPeers.self) { [unowned self] command in
            chatRelay.peers = command.peers.filter { $0.id != identity.id }
            return Done()
        }
        router.register(ChatCommands.AnswerRelay.self) { [unowned self] command in
            chatRelay.answer(command.answer)
            return Done()
        }
        router.register(ChatCommands.Finish.self) { [unowned self] command in
            try leadChat.finish(try requireChat(command.chatID))
            return Done()
        }
        router.register(ChatCommands.Reopen.self) { [unowned self] command in
            try leadChat.reopen(try requireChat(command.chatID))
            return Done()
        }
        router.register(ChatCommands.Delete.self) { [unowned self] command in
            let chat = try requireChat(command.chatID)
            let project = try requireProject(chat.projectId)
            try await leadChat.delete(chat, in: project, git: try requireGit(for: project))
            return Done()
        }
        router.register(ChatCommands.Rename.self) { [unowned self] command in
            _ = try database.renameChat(id: command.chatID, to: command.title)
            return Done()
        }
        router.register(ChatCommands.MarkViewed.self) { [unowned self] command in
            try database.markViewed(chatId: command.chatID)
            return Done()
        }
        router.register(ChatCommands.SetLead.self) { [unowned self] command in
            try leadChat.setLead(model: command.model, effort: command.effort, for: try requireChat(command.chatID))
            return Done()
        }
        router.register(ChatCommands.SetWorkflow.self) { [unowned self] command in
            try database.setWorkflow(command.workflow, chatId: command.chatID)
            return Done()
        }
        router.register(ChatCommands.StartProposal.self) { [unowned self] command in
            guard let proposal = try database.leadMessage(id: command.messageID) else { throw CommandFailure.notFound("The proposal") }
            guard proposal.status == .open else { throw CommandFailure.alreadyAnswered("This proposal") }
            if try database.task(id: proposal.taskId)?.isClosed == true {
                throw CommandFailure(code: .failed, message: "This request is closed. Send a message to reopen it first.")
            }
            let project = try requireProject(proposal.projectId)
            return try await leadChat.start(proposal, in: project)
        }
        router.register(ChatCommands.RejectProposal.self) { [unowned self] command in
            guard let proposal = try database.leadMessage(id: command.messageID) else { throw CommandFailure.notFound("The proposal") }
            guard proposal.status == .open else { throw CommandFailure.alreadyAnswered("This proposal") }
            try leadChat.reject(proposal)
            return Done()
        }
        router.register(ChatCommands.DismissProposal.self) { [unowned self] command in
            guard let proposal = try database.leadMessage(id: command.messageID) else { throw CommandFailure.notFound("The proposal") }
            guard proposal.status == .open else { throw CommandFailure.alreadyAnswered("This proposal") }
            try leadChat.dismiss(proposal)
            return Done()
        }
        router.register(ChatCommands.ApplySetupProposal.self) { [unowned self] command in
            guard let message = try database.leadMessage(id: command.messageID) else { throw CommandFailure.notFound("The setup") }
            guard message.status == .open else { throw CommandFailure.alreadyAnswered("This setup") }
            _ = try leadChat.applySetup(message, in: try requireProject(message.projectId))
            return Done()
        }
        router.register(ChatCommands.DismissSetupProposal.self) { [unowned self] command in
            guard let message = try database.leadMessage(id: command.messageID) else { throw CommandFailure.notFound("The setup") }
            guard message.status == .open else { throw CommandFailure.alreadyAnswered("This setup") }
            try leadChat.dismissSetup(message)
            return Done()
        }
        router.register(ChatCommands.OpenOnboarding.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            guard !project.isRemote else { throw CommandFailure(code: .failed, message: "Remote projects aren’t onboarded with the Lead.") }
            let scan = ProjectScanner.scanFiles(repository: project.filesRoot)
            return try await leadChat.openOnboarding(in: project, scan: scan)
        }
        router.register(ChatCommands.PostNotice.self) { [unowned self] command in
            _ = try database.createChatRequest(command.request)
            return Done()
        }
    }

    func heldRun(_ runID: Int64, requestID: Int64?, reasons: Set<HoldReason>) throws -> Run {
        let run = try requireRun(runID)
        let hold = engine.holds[runID] ?? (try? database.engineState(runId: runID))?.hold
        guard let hold, reasons.contains(hold.reason) else { throw CommandFailure.alreadyAnswered("This approval") }
        if let requestID {
            guard hold.requestId == nil || hold.requestId == requestID else { throw CommandFailure.alreadyAnswered("This approval") }
            if let request = try database.chatRequest(id: requestID), request.status != .open {
                throw CommandFailure.alreadyAnswered("This approval")
            }
        }
        return run
    }

    private func registerRunCommands() {
        router.register(RunCommands.Start.self) { [unowned self] command in
            let chat = try requireChat(command.chatID)
            let project = try requireProject(chat.projectId)
            guard let workflow = ProjectConfigLoader.load(repository: project.filesRoot).workflow(command.workflow) else {
                throw LeadChatError.unknownWorkflow(command.workflow)
            }
            return try engine.start(task: chat, workflow: workflow, project: project, title: command.title, brief: command.brief)
        }
        router.register(RunCommands.ApprovePlan.self) { [unowned self] command in
            try engine.approvePlan(try heldRun(command.runID, requestID: command.requestID, reasons: [.planApproval]), plan: command.plan)
            return Done()
        }
        router.register(RunCommands.RejectPlan.self) { [unowned self] command in
            try engine.rejectPlan(try heldRun(command.runID, requestID: command.requestID, reasons: [.planApproval]), note: command.note)
            return Done()
        }
        router.register(RunCommands.ResolveApproval.self) { [unowned self] command in
            try engine.resolveApproval(try heldRun(command.runID, requestID: command.requestID, reasons: [.approval]), approved: command.approved, note: command.note)
            return Done()
        }
        router.register(RunCommands.ResolveGates.self) { [unowned self] command in
            try engine.resolveGates(try heldRun(command.runID, requestID: command.requestID, reasons: [.gates]), proceed: command.proceed, note: command.note)
            return Done()
        }
        router.register(RunCommands.ResolveLoopLimit.self) { [unowned self] command in
            try engine.resolveLoopLimit(try heldRun(command.runID, requestID: command.requestID, reasons: [.loopLimit]), continueOnce: command.continueOnce)
            return Done()
        }
        router.register(RunCommands.ResolveFailure.self) { [unowned self] command in
            try engine.resolveFailure(try heldRun(command.runID, requestID: command.requestID, reasons: [.stepFailed, .timedOut]), retry: command.retry)
            return Done()
        }
        router.register(RunCommands.RetryStep.self) { [unowned self] command in
            try engine.retryStep(try requireRun(command.runID))
            return Done()
        }
        router.register(RunCommands.Pause.self) { [unowned self] command in
            try await engine.pause(try requireRun(command.runID))
            return Done()
        }
        router.register(RunCommands.Resume.self) { [unowned self] command in
            try engine.resume(try requireRun(command.runID))
            return Done()
        }
        router.register(RunCommands.Cancel.self) { [unowned self] command in
            try await engine.cancel(try requireRun(command.runID))
            return Done()
        }
        router.register(RunCommands.Merge.self) { [unowned self] command in
            try await engine.mergeDelivery(try requireRun(command.runID), method: command.method)
            return Done()
        }
        router.register(RunCommands.Push.self) { [unowned self] command in
            try await engine.push(try requireRun(command.runID))
        }
        router.register(RunCommands.DiffSummary.self) { [unowned self] command in
            await driver.diffInfo(try requireRun(command.runID))
        }
        router.register(RunCommands.AskToCombine.self) { [unowned self] command in
            try await driver.askToCombine(command.conflict, in: try requireRun(command.runID))
        }
        router.register(RunCommands.KeepBranch.self) { [unowned self] command in
            try await driver.keep(command.winner, resolving: command.conflict, in: try requireRun(command.runID))
            return Done()
        }
        router.register(RunCommands.StageForMergeTool.self) { [unowned self] command in
            let staged = try await driver.stageForMergeTool(command.conflict, in: try requireRun(command.runID))
            return StagedMerge(worktree: staged.worktree.path, files: staged.files)
        }
    }

    private func registerAgentCommands() {
        router.register(AgentCommands.Spawn.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            let sessions = try await runtime.spawn(
                in: project, kind: command.kind, count: command.count, git: try requireGit(for: project), pinned: command.pinned,
                name: command.name, model: command.model, task: command.task, skills: command.skills
            )
            return sessions.map(\.id)
        }
        router.register(AgentCommands.Send.self) { [unowned self] command in
            try requireSession(command.agentID).send(command.text, images: command.attachments)
            return Done()
        }
        router.register(AgentCommands.Perform.self) { [unowned self] command in
            let session = try requireSession(command.agentID)
            switch command.action {
            case .pause: session.pause()
            case .resume: session.resume()
            case .stop: session.stop()
            case .restart: session.restart()
            case .takeOver: session.takeOver()
            case .handBack: session.handBack()
            case .retrySetup: runtime.retrySetup(session)
            case .togglePin: session.togglePin()
            }
            return Done()
        }
        router.register(AgentCommands.SetPinned.self) { [unowned self] command in
            try requireSession(command.agentID).setPinned(command.pinned)
            return Done()
        }
        router.register(AgentCommands.SetModel.self) { [unowned self] command in
            guard ModelCatalog.isValid(command.model) else { throw AgentError.unknownModel(command.model) }
            try requireSession(command.agentID).setModel(command.model)
            return Done()
        }
        router.register(AgentCommands.Delete.self) { [unowned self] command in
            let session = try requireSession(command.agentID)
            let project = try requireProject(session.agent.projectId)
            try await runtime.delete(session, in: project, git: try requireGit(for: project), deleteBranch: command.deleteBranch)
            return Done()
        }
        router.register(AgentCommands.PauseAll.self) { [unowned self] command in
            try runtime.pauseAll(inProject: command.projectID)
        }
        router.register(AgentCommands.StartQueued.self) { [unowned self] command in
            runtime.startQueuedTurns(inProject: command.projectID)
            return Done()
        }
        router.register(AgentCommands.ReadMemory.self) { [unowned self] command in
            guard let agent = try database.agent(id: command.agentID) else { throw CommandFailure.notFound("The agent") }
            return runtime.memory(for: agent)?.read()
        }
        router.register(AgentCommands.WriteMemory.self) { [unowned self] command in
            guard let agent = try database.agent(id: command.agentID), let memory = runtime.memory(for: agent) else {
                throw CommandFailure.notFound("The agent’s memory")
            }
            if let text = command.text { try memory.write(text) } else { try memory.clear() }
            return Done()
        }
    }

    private func registerApprovalCommands() {
        router.register(ApprovalCommands.AnswerQuestion.self) { [unowned self] command in
            let answer = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw CommandFailure(code: .invalidArguments, message: "Type an answer first.") }
            guard let request = try database.chatRequest(id: command.requestID) else { throw CommandFailure.notFound("The question") }
            guard request.status == .open else { throw CommandFailure.alreadyAnswered("This question") }
            try database.resolveChatRequest(id: command.requestID, response: answer)
            if let agentID = request.agentId, let agent = try database.agent(id: agentID) {
                runtime.session(for: agent)?.send(answer)
            }
            return Done()
        }
        router.register(ApprovalCommands.AnswerPermission.self) { [unowned self] command in
            let request: PermissionRequest?
            if let id = command.permissionRequestID {
                request = try database.permissionRequest(id: id)
            } else if let id = command.chatRequestID {
                request = try database.permissionRequest(requestId: id)
            } else {
                request = nil
            }
            guard let request, let id = request.id else { throw CommandFailure.notFound("The permission request") }
            guard request.status == .pending else { throw CommandFailure.alreadyAnswered("This permission request") }
            try runtime.answerPermission(requestId: id, decision: command.decision)
            return Done()
        }
        router.register(ApprovalCommands.Dismiss.self) { [unowned self] command in
            guard let request = try database.chatRequest(id: command.requestID) else { throw CommandFailure.notFound("The request") }
            guard request.status == .open else { throw CommandFailure.alreadyAnswered("This request") }
            try database.resolveChatRequest(id: command.requestID, status: .dismissed)
            return Done()
        }
        router.register(ApprovalCommands.Resolve.self) { [unowned self] command in
            guard let request = try database.chatRequest(id: command.requestID) else { throw CommandFailure.notFound("The request") }
            guard request.status == .open else { throw CommandFailure.alreadyAnswered("This request") }
            try database.resolveChatRequest(id: command.requestID, response: command.response)
            return Done()
        }
    }

    private func registerSettingsCommands() {
        router.register(SettingsCommands.SetProviderMode.self) { [unowned self] command in
            try updateSettings { $0.providerMode = command.mode }
            return await checkEnvironment()
        }
        router.register(SettingsCommands.Get.self) { [unowned self] _ in settings }
        router.register(SettingsCommands.SaveAPIKey.self) { [unowned self] command in
            let key = command.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw CommandFailure(code: .invalidArguments, message: "The API key is empty.") }
            try secrets.write(key, for: .anthropicAPIKey)
            return await checkEnvironment()
        }
        router.register(SettingsCommands.RemoveAPIKey.self) { [unowned self] _ in
            try secrets.delete(.anthropicAPIKey)
            return await checkEnvironment()
        }
        router.register(SettingsCommands.CheckEnvironment.self) { [unowned self] _ in
            await checkEnvironment()
        }
        router.register(SettingsCommands.Status.self) { [unowned self] _ in status() }
        router.register(SettingsCommands.Shutdown.self) { [unowned self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                await self?.stop()
            }
            return Done()
        }
    }

    private func registerCodeCommands() {
        router.register(CodeCommands.ReadFile.self) { command in
            let url = URL(fileURLWithPath: command.path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try handle.read(upToCount: command.maximumBytes) ?? Data()
        }
        router.register(CodeCommands.WriteFile.self) { command in
            let url = URL(fileURLWithPath: command.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try command.data.write(to: url, options: .atomic)
            return Done()
        }
        router.register(CodeCommands.ListFiles.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            let output = try await requireGit(for: project).run(["ls-files", "--cached", "--others", "--exclude-standard"], in: project.url)
            return output.split(separator: "\n").map(String.init)
        }
        router.register(CodeCommands.UpdatePin.self) { [unowned self] command in
            guard try database.updatePin(id: command.pinID, status: command.status, response: command.response) != nil else { throw CommandFailure.notFound("The pin") }
            return Done()
        }
        router.register(CodeCommands.CreateComment.self) { [unowned self] command in
            try database.createComment(
                runId: command.runID, branchAgentId: command.branchAgentID, file: command.file, side: command.side,
                startLine: command.startLine, endLine: command.endLine, text: command.text
            )
            return Done()
        }
        router.register(CodeCommands.UpdateComment.self) { [unowned self] command in
            guard try database.updateComment(id: command.pinID, text: command.text) != nil else { throw CommandFailure.notFound("The comment") }
            return Done()
        }
        router.register(CodeCommands.DeletePin.self) { [unowned self] command in
            _ = try database.deletePin(id: command.pinID)
            return Done()
        }
        router.register(CodeCommands.ApproveOpenPins.self) { [unowned self] command in
            try database.approveOpenPins(runId: command.runID)
        }
        router.register(CodeCommands.SetViewed.self) { [unowned self] command in
            try database.setViewed(command.viewed, runId: command.runID, path: command.path, fingerprint: command.fingerprint)
            return Done()
        }
        router.register(CodeCommands.EncodeCorrection.self) { [unowned self] command in
            guard let correction = try await database.writer.read({ db in try Correction.fetchOne(db, id: command.correctionID) }) else {
                throw CommandFailure.notFound("The correction")
            }
            let project = try requireProject(correction.projectId)
            try await database.encode(correction, as: command.encoding, repository: project.url, git: try requireGit(for: project), files: project.filesRoot)
            return Done()
        }
        router.register(CodeCommands.Exec.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            let directory = command.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return ExecResult(try await requireGit(for: project).execute(command.arguments, in: directory))
        }
        router.register(CodeCommands.FileExists.self) { command in
            FileManager.default.fileExists(atPath: command.path)
        }
        router.register(CodeCommands.CreateDirectory.self) { command in
            try FileManager.default.createDirectory(atPath: command.path, withIntermediateDirectories: true)
            return Done()
        }
        router.register(CodeCommands.Subdirectories.self) { command in
            try await LocalFileSystem().subdirectories(of: URL(fileURLWithPath: command.path, isDirectory: true)).map(\.path)
        }
        router.register(CodeCommands.RemoveItem.self) { command in
            guard FileManager.default.fileExists(atPath: command.path) else { return Done() }
            try FileManager.default.removeItem(atPath: command.path)
            return Done()
        }
        router.register(CodeCommands.Git.self) { [unowned self] command in
            let project = try requireProject(command.projectID)
            let directory = command.directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? project.url
            return try await requireGit(for: project).run(command.arguments, in: directory)
        }
    }

    private func registerRemoteAccessCommands() {
        router.register(RemoteAccessCommands.Status.self) { [unowned self] _ in
            try remoteAccessStatus()
        }
        router.register(RemoteAccessCommands.SetEnabled.self) { [unowned self] command in
            let remote = try requireRemoteAccess()
            let current = settings.remoteAccess ?? RemoteAccessSettings()
            let port = command.port ?? current.port
            guard port == 0 || (1024...65535).contains(port) else { throw CommandFailure(code: .invalidArguments, message: "Use a port from 1024 to 65535.") }
            if command.enabled {
                try await remote.start(port: port)
            } else {
                await remote.stop()
            }
            let saved = RemoteAccessSettings(enabled: command.enabled, port: remote.port ?? port)
            try updateSettings { $0.remoteAccess = saved }
            return try remoteAccessStatus()
        }
        router.register(RemoteAccessCommands.BeginPairing.self) { [unowned self] _ in
            let remote = try requireRemoteAccess()
            guard remote.isListening else { throw CommandFailure(code: .failed, message: "Turn on Remote access before pairing a device.") }
            return remote.beginPairing()
        }
        router.register(RemoteAccessCommands.Revoke.self) { [unowned self] command in
            let remote = try requireRemoteAccess()
            guard try remote.revoke(command.deviceID) else { throw CommandFailure.notFound("The device") }
            server?.closeSessions(of: command.deviceID)
            return Done()
        }
    }

    private func requireRemoteAccess() throws -> RemoteAccessServer {
        guard let remote = server?.remoteAccess else {
            throw CommandFailure(code: .failed, message: "Remote access needs the daemon to be listening for clients.")
        }
        return remote
    }

    private func remoteAccessStatus() throws -> RemoteAccessStatus {
        let remote = try requireRemoteAccess()
        let saved = settings.remoteAccess ?? RemoteAccessSettings()
        return RemoteAccessStatus(
            enabled: remote.isListening, port: remote.port ?? saved.port,
            addresses: remote.addresses, pairedDevices: remote.devices
        )
    }
}
