import Foundation

public struct WorktreeInfo: Codable, Sendable, Hashable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(_ worktree: Worktree) {
        path = worktree.path.path
        head = worktree.head
        branch = worktree.branch
        isLocked = worktree.isLocked
        isPrunable = worktree.isPrunable
    }

    public var worktree: Worktree {
        Worktree(path: URL(fileURLWithPath: path, isDirectory: true), head: head, branch: branch, isLocked: isLocked, isPrunable: isPrunable)
    }
}

public struct ProjectStatus: Codable, Sendable, Hashable {
    public var branch: String?
    public var worktrees: [WorktreeInfo]
    public var pruned: [WorktreeInfo]
    public var orphanedDirectories: [String]
    public var missing: Bool

    public init(branch: String? = nil, worktrees: [WorktreeInfo] = [], pruned: [WorktreeInfo] = [], orphanedDirectories: [String] = [], missing: Bool = false) {
        self.branch = branch
        self.worktrees = worktrees
        self.pruned = pruned
        self.orphanedDirectories = orphanedDirectories
        self.missing = missing
    }

    public var recovery: WorktreeRecovery {
        WorktreeRecovery(
            worktrees: worktrees.map(\.worktree), pruned: pruned.map(\.worktree),
            orphanedDirectories: orphanedDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}

public enum ProjectCommands {
    public struct Open: DaemonCommand {
        public static let name = "project.open"
        public typealias Response = Project
        public var path: String
        public init(path: String) { self.path = path }
    }

    public struct OpenRemote: DaemonCommand {
        public static let name = "project.openRemote"
        public typealias Response = Project
        public var host: String
        public var path: String
        public init(host: String, path: String) {
            self.host = host
            self.path = path
        }
    }

    public struct Clone: DaemonCommand {
        public static let name = "project.clone"
        public typealias Response = Project
        public var remote: String
        public var destination: String
        public init(remote: String, destination: String) {
            self.remote = remote
            self.destination = destination
        }
    }

    public struct Close: DaemonCommand {
        public static let name = "project.close"
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct Forget: DaemonCommand {
        public static let name = "project.forget"
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct Rename: DaemonCommand {
        public static let name = "project.rename"
        public var projectID: Int64
        public var name: String
        public init(projectID: Int64, name: String) {
            self.projectID = projectID
            self.name = name
        }
    }

    public struct UpdateSettings: DaemonCommand {
        public static let name = "project.updateSettings"
        public var projectID: Int64
        public var settings: ProjectSettings
        public init(projectID: Int64, settings: ProjectSettings) {
            self.projectID = projectID
            self.settings = settings
        }
    }

    public struct Refresh: DaemonCommand {
        public static let name = "project.refresh"
        public typealias Response = ProjectStatus
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct ConfigFiles: DaemonCommand {
        public static let name = "project.configFiles"
        public typealias Response = [String: Data]
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct CheckHarness: DaemonCommand {
        public static let name = "project.checkHarness"
        public typealias Response = HarnessReport
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct InstallDefaults: DaemonCommand {
        public static let name = "project.installDefaults"
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct CreateWorktree: DaemonCommand {
        public static let name = "project.createWorktree"
        public var projectID: Int64
        public var agent: String
        public var slug: String
        public init(projectID: Int64, agent: String, slug: String) {
            self.projectID = projectID
            self.agent = agent
            self.slug = slug
        }
    }

    public struct RemoveWorktree: DaemonCommand {
        public static let name = "project.removeWorktree"
        public var projectID: Int64
        public var path: String
        public var force: Bool
        public var deleteBranch: Bool
        public init(projectID: Int64, path: String, force: Bool, deleteBranch: Bool) {
            self.projectID = projectID
            self.path = path
            self.force = force
            self.deleteBranch = deleteBranch
        }
    }

    public struct DeleteOrphanedDirectory: DaemonCommand {
        public static let name = "project.deleteOrphanedDirectory"
        public var projectID: Int64
        public var path: String
        public init(projectID: Int64, path: String) {
            self.projectID = projectID
            self.path = path
        }
    }
}

public enum ChatCommands {
    public struct Create: DaemonCommand {
        public static let name = "chat.create"
        public typealias Response = Chat
        public var projectID: Int64
        public var text: String
        public var attachments: [ChatAttachment]
        public var workflow: String?
        public var leadModel: String?
        public var leadEffort: LeadEffort?
        public init(projectID: Int64, text: String, attachments: [ChatAttachment] = [], workflow: String? = nil, leadModel: String? = nil, leadEffort: LeadEffort? = nil) {
            self.projectID = projectID
            self.text = text
            self.attachments = attachments
            self.workflow = workflow
            self.leadModel = leadModel
            self.leadEffort = leadEffort
        }
    }

    public struct CreateEmpty: DaemonCommand {
        public static let name = "chat.createEmpty"
        public typealias Response = Chat
        public var projectID: Int64
        public var title: String
        public var body: String
        public init(projectID: Int64, title: String, body: String = "") {
            self.projectID = projectID
            self.title = title
            self.body = body
        }
    }

    public struct Send: DaemonCommand {
        public static let name = "chat.send"
        public var chatID: Int64
        public var text: String
        public var attachments: [ChatAttachment]
        public init(chatID: Int64, text: String, attachments: [ChatAttachment] = []) {
            self.chatID = chatID
            self.text = text
            self.attachments = attachments
        }
    }

    public struct Close: DaemonCommand {
        public static let name = "chat.close"
        public typealias Response = Chat
        public var chatID: Int64
        public var reason: RequestCloseReason
        public init(chatID: Int64, reason: RequestCloseReason) {
            self.chatID = chatID
            self.reason = reason
        }
    }

    public struct ReviewSpec: DaemonCommand {
        public static let name = "chat.reviewSpec"
        public typealias Response = SpecReviewStatus
        public var chatID: Int64
        public init(chatID: Int64) { self.chatID = chatID }
    }

    public struct Finish: DaemonCommand {
        public static let name = "chat.finish"
        public var chatID: Int64
        public init(chatID: Int64) { self.chatID = chatID }
    }

    public struct Reopen: DaemonCommand {
        public static let name = "chat.reopen"
        public var chatID: Int64
        public init(chatID: Int64) { self.chatID = chatID }
    }

    public struct Delete: DaemonCommand {
        public static let name = "chat.delete"
        public var chatID: Int64
        public init(chatID: Int64) { self.chatID = chatID }
    }

    public struct Rename: DaemonCommand {
        public static let name = "chat.rename"
        public var chatID: Int64
        public var title: String
        public init(chatID: Int64, title: String) {
            self.chatID = chatID
            self.title = title
        }
    }

    public struct MarkViewed: DaemonCommand {
        public static let name = "chat.markViewed"
        public var chatID: Int64
        public init(chatID: Int64) { self.chatID = chatID }
    }

    public struct SetLead: DaemonCommand {
        public static let name = "chat.setLead"
        public var chatID: Int64
        public var model: String?
        public var effort: LeadEffort?
        public init(chatID: Int64, model: String?, effort: LeadEffort?) {
            self.chatID = chatID
            self.model = model
            self.effort = effort
        }
    }

    public struct SetWorkflow: DaemonCommand {
        public static let name = "chat.setWorkflow"
        public var chatID: Int64
        public var workflow: String?
        public init(chatID: Int64, workflow: String?) {
            self.chatID = chatID
            self.workflow = workflow
        }
    }

    public struct StartProposal: DaemonCommand {
        public static let name = "chat.startProposal"
        public typealias Response = Run
        public var messageID: Int64
        public init(messageID: Int64) { self.messageID = messageID }
    }

    public struct RejectProposal: DaemonCommand {
        public static let name = "chat.rejectProposal"
        public var messageID: Int64
        public init(messageID: Int64) { self.messageID = messageID }
    }

    public struct DismissProposal: DaemonCommand {
        public static let name = "chat.dismissProposal"
        public var messageID: Int64
        public init(messageID: Int64) { self.messageID = messageID }
    }

    public struct PostNotice: DaemonCommand {
        public static let name = "chat.postNotice"
        public var request: ChatRequest
        public init(request: ChatRequest) { self.request = request }
    }
}

public enum RunCommands {
    public struct Start: DaemonCommand {
        public static let name = "run.start"
        public typealias Response = Run
        public var chatID: Int64
        public var workflow: String
        public var title: String?
        public var brief: String?
        public init(chatID: Int64, workflow: String, title: String? = nil, brief: String? = nil) {
            self.chatID = chatID
            self.workflow = workflow
            self.title = title
            self.brief = brief
        }
    }

    public struct ApprovePlan: DaemonCommand {
        public static let name = "run.approvePlan"
        public var runID: Int64
        public var plan: Plan
        public var requestID: Int64?
        public init(runID: Int64, plan: Plan, requestID: Int64? = nil) {
            self.runID = runID
            self.plan = plan
            self.requestID = requestID
        }
    }

    public struct RejectPlan: DaemonCommand {
        public static let name = "run.rejectPlan"
        public var runID: Int64
        public var note: String
        public var requestID: Int64?
        public init(runID: Int64, note: String, requestID: Int64? = nil) {
            self.runID = runID
            self.note = note
            self.requestID = requestID
        }
    }

    public struct ResolveApproval: DaemonCommand {
        public static let name = "run.resolveApproval"
        public var runID: Int64
        public var approved: Bool
        public var note: String?
        public var requestID: Int64?
        public init(runID: Int64, approved: Bool, note: String? = nil, requestID: Int64? = nil) {
            self.runID = runID
            self.approved = approved
            self.note = note
            self.requestID = requestID
        }
    }

    public struct ResolveGates: DaemonCommand {
        public static let name = "run.resolveGates"
        public var runID: Int64
        public var proceed: Bool
        public var note: String?
        public var requestID: Int64?
        public init(runID: Int64, proceed: Bool, note: String? = nil, requestID: Int64? = nil) {
            self.runID = runID
            self.proceed = proceed
            self.note = note
            self.requestID = requestID
        }
    }

    public struct ResolveLoopLimit: DaemonCommand {
        public static let name = "run.resolveLoopLimit"
        public var runID: Int64
        public var continueOnce: Bool
        public var requestID: Int64?
        public init(runID: Int64, continueOnce: Bool, requestID: Int64? = nil) {
            self.runID = runID
            self.continueOnce = continueOnce
            self.requestID = requestID
        }
    }

    public struct ResolveBudget: DaemonCommand {
        public static let name = "run.resolveBudget"
        public var runID: Int64
        public var proceed: Bool
        public var raiseRunBudgetTo: Double?
        public var requestID: Int64?
        public init(runID: Int64, proceed: Bool, raiseRunBudgetTo: Double? = nil, requestID: Int64? = nil) {
            self.runID = runID
            self.proceed = proceed
            self.raiseRunBudgetTo = raiseRunBudgetTo
            self.requestID = requestID
        }
    }

    public struct ResolveFailure: DaemonCommand {
        public static let name = "run.resolveFailure"
        public var runID: Int64
        public var retry: Bool
        public var requestID: Int64?
        public init(runID: Int64, retry: Bool, requestID: Int64? = nil) {
            self.runID = runID
            self.retry = retry
            self.requestID = requestID
        }
    }

    public struct RetryStep: DaemonCommand {
        public static let name = "run.retryStep"
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct Pause: DaemonCommand {
        public static let name = "run.pause"
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct Resume: DaemonCommand {
        public static let name = "run.resume"
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct Cancel: DaemonCommand {
        public static let name = "run.cancel"
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct Merge: DaemonCommand {
        public static let name = "run.merge"
        public var runID: Int64
        public var method: MergeMethod
        public init(runID: Int64, method: MergeMethod) {
            self.runID = runID
            self.method = method
        }
    }

    public struct Push: DaemonCommand {
        public static let name = "run.push"
        public typealias Response = String
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct DiffSummary: DaemonCommand {
        public static let name = "run.diffSummary"
        public typealias Response = DiffInfo
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct AskToCombine: DaemonCommand {
        public static let name = "run.askToCombine"
        public typealias Response = String
        public var runID: Int64
        public var conflict: MergeConflict
        public init(runID: Int64, conflict: MergeConflict) {
            self.runID = runID
            self.conflict = conflict
        }
    }

    public struct KeepBranch: DaemonCommand {
        public static let name = "run.keepBranch"
        public var runID: Int64
        public var winner: String
        public var conflict: MergeConflict
        public init(runID: Int64, winner: String, conflict: MergeConflict) {
            self.runID = runID
            self.winner = winner
            self.conflict = conflict
        }
    }

    public struct StageForMergeTool: DaemonCommand {
        public static let name = "run.stageForMergeTool"
        public typealias Response = StagedMerge
        public var runID: Int64
        public var conflict: MergeConflict
        public init(runID: Int64, conflict: MergeConflict) {
            self.runID = runID
            self.conflict = conflict
        }
    }
}

public struct StagedMerge: Codable, Sendable, Hashable {
    public var worktree: String
    public var files: [String]
}

public enum AgentAction: String, Codable, Sendable {
    case pause
    case resume
    case stop
    case restart
    case takeOver
    case handBack
    case retrySetup
    case togglePin
}

public enum AgentCommands {
    public struct Spawn: DaemonCommand {
        public static let name = "agent.spawn"
        public typealias Response = [Int64]
        public var projectID: Int64
        public var kind: AgentKind
        public var count: Int
        public var name: String?
        public var model: String?
        public var skills: [String]
        public var pinned: Bool
        public var task: String
        public init(projectID: Int64, kind: AgentKind, count: Int, name: String?, model: String?, skills: [String], pinned: Bool, task: String) {
            self.projectID = projectID
            self.kind = kind
            self.count = count
            self.name = name
            self.model = model
            self.skills = skills
            self.pinned = pinned
            self.task = task
        }
    }

    public struct Send: DaemonCommand {
        public static let name = "agent.send"
        public var agentID: Int64
        public var text: String
        public var attachments: [ChatAttachment]
        public init(agentID: Int64, text: String, attachments: [ChatAttachment] = []) {
            self.agentID = agentID
            self.text = text
            self.attachments = attachments
        }
    }

    public struct Perform: DaemonCommand {
        public static let name = "agent.perform"
        public var agentID: Int64
        public var action: AgentAction
        public init(agentID: Int64, action: AgentAction) {
            self.agentID = agentID
            self.action = action
        }
    }

    public struct SetPinned: DaemonCommand {
        public static let name = "agent.setPinned"
        public var agentID: Int64
        public var pinned: Bool
        public init(agentID: Int64, pinned: Bool) {
            self.agentID = agentID
            self.pinned = pinned
        }
    }

    public struct SetModel: DaemonCommand {
        public static let name = "agent.setModel"
        public var agentID: Int64
        public var model: String
        public init(agentID: Int64, model: String) {
            self.agentID = agentID
            self.model = model
        }
    }

    public struct Delete: DaemonCommand {
        public static let name = "agent.delete"
        public var agentID: Int64
        public var deleteBranch: Bool
        public init(agentID: Int64, deleteBranch: Bool) {
            self.agentID = agentID
            self.deleteBranch = deleteBranch
        }
    }

    public struct PauseAll: DaemonCommand {
        public static let name = "agent.pauseAll"
        public typealias Response = Int
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct StartQueued: DaemonCommand {
        public static let name = "agent.startQueued"
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct WriteMemory: DaemonCommand {
        public static let name = "agent.writeMemory"
        public var agentID: Int64
        public var text: String?
        public init(agentID: Int64, text: String?) {
            self.agentID = agentID
            self.text = text
        }
    }

    public struct ReadMemory: DaemonCommand {
        public static let name = "agent.readMemory"
        public typealias Response = String?
        public var agentID: Int64
        public init(agentID: Int64) { self.agentID = agentID }
    }
}

public enum ApprovalCommands {
    public struct AnswerQuestion: DaemonCommand {
        public static let name = "approval.answerQuestion"
        public var requestID: Int64
        public var text: String
        public init(requestID: Int64, text: String) {
            self.requestID = requestID
            self.text = text
        }
    }

    public struct AnswerPermission: DaemonCommand {
        public static let name = "approval.answerPermission"
        public var permissionRequestID: Int64?
        public var chatRequestID: Int64?
        public var decision: PermissionDecision
        public init(permissionRequestID: Int64? = nil, chatRequestID: Int64? = nil, decision: PermissionDecision) {
            self.permissionRequestID = permissionRequestID
            self.chatRequestID = chatRequestID
            self.decision = decision
        }
    }

    public struct Dismiss: DaemonCommand {
        public static let name = "approval.dismiss"
        public var requestID: Int64
        public init(requestID: Int64) { self.requestID = requestID }
    }

    public struct Resolve: DaemonCommand {
        public static let name = "approval.resolve"
        public var requestID: Int64
        public var response: String?
        public init(requestID: Int64, response: String?) {
            self.requestID = requestID
            self.response = response
        }
    }
}

public enum SettingsCommands {
    public struct SetProviderMode: DaemonCommand {
        public static let name = "settings.setProviderMode"
        public typealias Response = DaemonEnvironment
        public var mode: ProviderMode
        public init(mode: ProviderMode) { self.mode = mode }
    }

    public struct SetBudgets: DaemonCommand {
        public static let name = "settings.setBudgets"
        public var monthlyUSD: Double?
        public var weeklyUSD: Double?
        public init(monthlyUSD: Double?, weeklyUSD: Double?) {
            self.monthlyUSD = monthlyUSD
            self.weeklyUSD = weeklyUSD
        }
    }

    public struct Get: DaemonCommand {
        public static let name = "settings.get"
        public typealias Response = DaemonSettings
        public init() {}
    }

    public struct SaveAPIKey: DaemonCommand {
        public static let name = "settings.saveAPIKey"
        public typealias Response = DaemonEnvironment
        public var key: String
        public init(key: String) { self.key = key }
    }

    public struct RemoveAPIKey: DaemonCommand {
        public static let name = "settings.removeAPIKey"
        public typealias Response = DaemonEnvironment
        public init() {}
    }

    public struct CheckEnvironment: DaemonCommand {
        public static let name = "settings.checkEnvironment"
        public typealias Response = DaemonEnvironment
        public init() {}
    }

    public struct Status: DaemonCommand {
        public static let name = "settings.status"
        public typealias Response = DaemonStatus
        public init() {}
    }

    public struct Shutdown: DaemonCommand {
        public static let name = "settings.shutdown"
        public init() {}
    }
}

public struct DaemonStatus: Codable, Sendable, Hashable {
    public var identity: DaemonIdentity
    public var buildVersion: String
    public var pid: Int32
    public var dataDirectory: String
    public var activeRuns: Int
    public var runningAgents: Int
    public var clients: Int
    public var environment: DaemonEnvironment
    public var startedAt: Date
}

public enum CodeCommands {
    public struct ReadFile: DaemonCommand {
        public static let name = "code.readFile"
        public typealias Response = Data?
        public var path: String
        public var maximumBytes: Int
        public init(path: String, maximumBytes: Int = 4 * 1024 * 1024) {
            self.path = path
            self.maximumBytes = maximumBytes
        }
    }

    public struct WriteFile: DaemonCommand {
        public static let name = "code.writeFile"
        public var path: String
        public var data: Data
        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct ListFiles: DaemonCommand {
        public static let name = "code.listFiles"
        public typealias Response = [String]
        public var projectID: Int64
        public init(projectID: Int64) { self.projectID = projectID }
    }

    public struct Git: DaemonCommand {
        public static let name = "code.git"
        public typealias Response = String
        public var projectID: Int64
        public var arguments: [String]
        public var directory: String?
        public init(projectID: Int64, arguments: [String], directory: String? = nil) {
            self.projectID = projectID
            self.arguments = arguments
            self.directory = directory
        }
    }

    public struct Exec: DaemonCommand {
        public static let name = "code.exec"
        public typealias Response = ExecResult
        public var projectID: Int64
        public var arguments: [String]
        public var directory: String?
        public init(projectID: Int64, arguments: [String], directory: String?) {
            self.projectID = projectID
            self.arguments = arguments
            self.directory = directory
        }
    }

    public struct FileExists: DaemonCommand {
        public static let name = "code.fileExists"
        public typealias Response = Bool
        public var path: String
        public init(path: String) { self.path = path }
    }

    public struct CreateDirectory: DaemonCommand {
        public static let name = "code.createDirectory"
        public var path: String
        public init(path: String) { self.path = path }
    }

    public struct Subdirectories: DaemonCommand {
        public static let name = "code.subdirectories"
        public typealias Response = [String]
        public var path: String
        public init(path: String) { self.path = path }
    }

    public struct RemoveItem: DaemonCommand {
        public static let name = "code.removeItem"
        public var path: String
        public init(path: String) { self.path = path }
    }

    public struct UpdatePin: DaemonCommand {
        public static let name = "code.updatePin"
        public var pinID: Int64
        public var status: PinStatus
        public var response: String?
        public init(pinID: Int64, status: PinStatus, response: String?) {
            self.pinID = pinID
            self.status = status
            self.response = response
        }
    }

    public struct CreateComment: DaemonCommand {
        public static let name = "code.createComment"
        public var runID: Int64
        public var branchAgentID: Int64?
        public var file: String
        public var side: PinSide
        public var startLine: Int
        public var endLine: Int
        public var text: String
        public init(runID: Int64, branchAgentID: Int64?, file: String, side: PinSide, startLine: Int, endLine: Int, text: String) {
            self.runID = runID
            self.branchAgentID = branchAgentID
            self.file = file
            self.side = side
            self.startLine = startLine
            self.endLine = endLine
            self.text = text
        }
    }

    public struct UpdateComment: DaemonCommand {
        public static let name = "code.updateComment"
        public var pinID: Int64
        public var text: String
        public init(pinID: Int64, text: String) {
            self.pinID = pinID
            self.text = text
        }
    }

    public struct DeletePin: DaemonCommand {
        public static let name = "code.deletePin"
        public var pinID: Int64
        public init(pinID: Int64) { self.pinID = pinID }
    }

    public struct ApproveOpenPins: DaemonCommand {
        public static let name = "code.approveOpenPins"
        public typealias Response = Int
        public var runID: Int64
        public init(runID: Int64) { self.runID = runID }
    }

    public struct SetViewed: DaemonCommand {
        public static let name = "code.setViewed"
        public var runID: Int64
        public var path: String
        public var fingerprint: String
        public var viewed: Bool
        public init(runID: Int64, path: String, fingerprint: String, viewed: Bool) {
            self.runID = runID
            self.path = path
            self.fingerprint = fingerprint
            self.viewed = viewed
        }
    }

    public struct EncodeCorrection: DaemonCommand {
        public static let name = "code.encodeCorrection"
        public var correctionID: Int64
        public var encoding: CorrectionEncoding
        public init(correctionID: Int64, encoding: CorrectionEncoding) {
            self.correctionID = correctionID
            self.encoding = encoding
        }
    }
}
