import Foundation
import GRDB
import Observation
import Yams

public enum RunEngineError: Error, LocalizedError, Equatable {
    case runNotFound
    case notWaiting(HoldReason)
    case invalidState(String)
    case emptyWorkflow(String)
    case unknownStep(String)
    case noApprovedPlan
    case unroutedOutcome(step: String, outcome: String)
    case timedOut(step: String, minutes: Int)

    public var errorDescription: String? {
        switch self {
        case .runNotFound: "This run no longer exists."
        case .notWaiting(let reason): "This run isn’t waiting for \(reason.rawValue.replacingOccurrences(of: "_", with: " "))."
        case .invalidState(let message): message
        case .emptyWorkflow(let name): "The workflow “\(name)” has no steps."
        case .unknownStep(let id): "The workflow has no step “\(id)”."
        case .noApprovedPlan: "There is no approved plan to build from."
        case .unroutedOutcome(let step, let outcome): "Step “\(step)” finished with “\(outcome)”, which has no route."
        case .timedOut(let step, let minutes): "Step “\(step)” ran longer than \(minutes) minutes."
        }
    }
}

@MainActor
@Observable
public final class RunEngine {
    public let database: AppDatabase
    public private(set) var runs: [Int64: Run] = [:]
    public private(set) var holds: [Int64: RunHold] = [:]
    public internal(set) var waitingForCapacity: Set<Int64> = []
    @ObservationIgnored public var capacityPollInterval: Duration = .seconds(2)
    @ObservationIgnored public var approvedWorkers: @MainActor (_ runID: Int64) -> [SpecWorker]? = { _ in nil }
    @ObservationIgnored public var leadShouldHandle: (@MainActor (_ run: Run, _ hold: RunHold, _ brief: String) -> Void)?
    @ObservationIgnored public var mergeFailed: (@MainActor (_ run: Run, _ error: String) -> Void)?

    @ObservationIgnored let driver: any WorkflowDriver
    @ObservationIgnored let minute: Duration
    @ObservationIgnored let clock: @MainActor () -> Date
    @ObservationIgnored private var drivers: [Int64: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var workflowCache: [Int64: WorkflowDefinition] = [:]
    @ObservationIgnored private var mergingRuns: Set<Int64> = []
    @ObservationIgnored private var pushingRuns: Set<Int64> = []
    @ObservationIgnored private var suspectedOrphans: Set<Int64> = []
    @ObservationIgnored private var orphanWatchdog: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored var debugTrace: DebugTrace?
    #endif

    public init(database: AppDatabase, driver: any WorkflowDriver, minute: Duration = .seconds(60), clock: @escaping @MainActor () -> Date = { .now }) {
        self.database = database
        self.driver = driver
        self.minute = minute
        self.clock = clock
        if let paths = (driver as? AgentWorkflowDriver)?.runtime.paths {
            self.approvedWorkers = { runID in SpecApproval.workers(runId: runID, paths: paths) }
        }
        #if DEBUG
        self.debugTrace = (driver as? AgentWorkflowDriver)?.runtime.debugTrace
        #endif
    }

    public func activeRuns(projectID: Int64) -> [Run] {
        runs.values
            .filter { $0.projectId == projectID }
            .sorted { ($0.startedAt, $0.id ?? 0) < ($1.startedAt, $1.id ?? 0) }
    }

    public func waitingReason(runID: Int64) -> RunHold? {
        holds[runID]
    }

    public func isDriving(runID: Int64) -> Bool {
        drivers[runID] != nil
    }

    public func workflow(for run: Run) throws -> WorkflowDefinition {
        if let id = run.id, let cached = workflowCache[id] { return cached }
        var workflow = try YAMLDecoder().decode(WorkflowDefinition.self, from: run.workflowSnapshot)
        workflow.id = run.workflow
        if let id = run.id { workflowCache[id] = workflow }
        return workflow
    }

    @discardableResult
    public func start(task: Chat, workflow: WorkflowDefinition, project: Project, title: String? = nil, brief: String? = nil) throws -> Run {
        guard let first = workflow.firstStep else { throw RunEngineError.emptyWorkflow(workflow.name) }
        guard let projectId = project.id, let taskId = task.id else { throw RunEngineError.invalidState("Save the task and project before starting a run.") }
        let now = clock()
        let draft = Run(
            projectId: projectId, taskId: taskId, workflow: workflow.id, workflowVersion: String(workflow.version),
            currentStep: first.id, status: .running, startedAt: now, title: title ?? task.title,
            workflowSnapshot: try ProjectConfigLoader.encodeYAML(workflow),
            endAction: workflow.end.action.rawValue, brief: brief
        )
        let state = RunEngineState(cursor: RunCursor(stepId: first.id, iteration: 1))
        let run = try database.insert(draft, state: state)
        guard let runID = run.id else { throw RunEngineError.runNotFound }
        try database.writer.write { db in
            try db.execute(sql: "UPDATE task SET status = ?, workflow = ?, updatedAt = ? WHERE id = ?", arguments: [ChatStatus.running.rawValue, workflow.id, now, taskId])
        }
        refresh(run, state: state)
        #if DEBUG
        traceRunStarted(run, workflow: workflow)
        #endif
        launch(runID)
        return run
    }

    public func approvePlan(_ run: Run, plan: Plan) throws {
        var loaded = try load(run)
        let hold = try requireHold(loaded, .planApproval)
        guard let runStepId = hold.runStepId, var runStep = try database.runStep(id: runStepId),
              let step = loaded.workflow.step(hold.stepId) else { throw RunEngineError.invalidState("The plan step is missing.") }
        var output = decodeOutput(runStep.output)
        output.plan = plan
        output.summary = plan.summary
        runStep.output = encode(output)
        runStep.status = .succeeded
        runStep.endedAt = clock()
        try release(&loaded, response: "approved")
        if try route(&loaded, from: step, outcome: hold.outcome ?? StepOutcome.done, output: output, steps: [runStep]) {
            launch(try loaded.id)
        }
    }

    public func rejectPlan(_ run: Run, note: String) throws {
        var loaded = try load(run)
        let hold = try requireHold(loaded, .planApproval)
        guard let runStepId = hold.runStepId, var runStep = try database.runStep(id: runStepId) else {
            throw RunEngineError.invalidState("The plan step is missing.")
        }
        runStep.status = .failed
        runStep.outcome = "rejected"
        runStep.endedAt = clock()
        try release(&loaded, response: note, decision: "rejected")
        loaded.state.feedback = Feedback(fromStep: hold.stepId, outcome: "rejected", summary: note)
        loaded.state.cursor = RunCursor(stepId: hold.stepId, iteration: try nextIteration(of: hold.stepId, runID: loaded.id))
        try commit(loaded, steps: [runStep])
        launch(try loaded.id)
    }

    public func resolveApproval(_ run: Run, approved: Bool, note: String? = nil) throws {
        var loaded = try load(run)
        let hold = try requireHold(loaded, .approval)
        guard let runStepId = hold.runStepId, var runStep = try database.runStep(id: runStepId),
              let step = loaded.workflow.step(hold.stepId) else { throw RunEngineError.invalidState("The approval step is missing.") }
        let outcome = approved ? StepOutcome.approved : StepOutcome.changesRequested
        let verdict = Verdict(outcome: outcome, summary: note ?? (approved ? "Approved" : "Changes requested"))
        let output = StepOutput(verdict: verdict, summary: verdict.summary)
        runStep.outcome = outcome
        runStep.output = encode(output)
        runStep.status = .succeeded
        runStep.endedAt = clock()
        try release(&loaded, response: note ?? outcome, decision: outcome)
        if approved { loaded.state.reviewNotes = [] }
        if try route(&loaded, from: step, outcome: outcome, output: output, steps: [runStep]) {
            launch(try loaded.id)
        }
    }

    public func resolveGates(_ run: Run, proceed: Bool, note: String? = nil) throws {
        var loaded = try load(run)
        let hold = try requireHold(loaded, .gates)
        guard let runStepId = hold.runStepId, var runStep = try database.runStep(id: runStepId),
              let step = loaded.workflow.step(hold.stepId) else { throw RunEngineError.invalidState("The gates step is missing.") }
        var output = decodeOutput(runStep.output)
        runStep.endedAt = clock()
        if proceed {
            runStep.status = .succeeded
            runStep.outcome = StepOutcome.passed
            output.summary = (output.summary ?? "") + " You continued past them."
            runStep.output = encode(output)
            try release(&loaded, response: note ?? "continue", decision: StepOutcome.passed)
            if try route(&loaded, from: step, outcome: StepOutcome.passed, output: output, steps: [runStep]) {
                launch(try loaded.id)
            }
            return
        }
        guard let target = step.routes[StepOutcome.changesRequested]?.to ?? Self.authorStep(before: step, in: loaded.workflow) else {
            throw RunEngineError.invalidState("There is no step to send the work back to.")
        }
        runStep.status = .succeeded
        runStep.outcome = StepOutcome.changesRequested
        runStep.output = encode(output)
        try release(&loaded, response: note ?? "send back", decision: StepOutcome.changesRequested)
        loaded.state.feedback = Feedback(
            fromStep: step.id, outcome: StepOutcome.changesRequested,
            summary: note.flatMap { $0.isEmpty ? nil : $0 } ?? "The user sent the work back over these gate findings.",
            issues: output.gates?.blocking.map(\.issue) ?? []
        )
        loaded.state.cursor = RunCursor(stepId: target, iteration: try nextIteration(of: target, runID: loaded.id))
        loaded.run.currentStep = target
        try commit(loaded, steps: [runStep])
        launch(try loaded.id)
    }

    public func resolveLoopLimit(_ run: Run, continueOnce: Bool) throws {
        var loaded = try load(run)
        let hold = try requireHold(loaded, .loopLimit)
        guard continueOnce else {
            try fail(&loaded, message: hold.message, response: "fail")
            return
        }
        guard let step = loaded.workflow.step(hold.stepId), let outcome = hold.outcome else {
            throw RunEngineError.invalidState("The looping step is missing.")
        }
        let key = RunEngineState.loopKey(from: step.id, outcome: outcome)
        loaded.state.extraLoops[key, default: 0] += 1
        try release(&loaded, response: "continue")
        let output = try latestOutput(of: step.id, runID: loaded.id)
        if try route(&loaded, from: step, outcome: outcome, output: output, steps: []) {
            launch(try loaded.id)
        }
    }

    public func resolveFailure(_ run: Run, retry: Bool) throws {
        var loaded = try load(run)
        guard let hold = loaded.state.hold, [.stepFailed, .timedOut].contains(hold.reason) else {
            throw RunEngineError.notWaiting(.stepFailed)
        }
        if retry {
            try retryStep(run)
        } else {
            try fail(&loaded, message: hold.message, response: "fail")
        }
    }

    public func retryStep(_ run: Run) throws {
        var loaded = try load(run)
        let retryable = loaded.run.status == .failed
            || loaded.state.hold.map { [.stepFailed, .timedOut].contains($0.reason) } == true
        guard retryable, var cursor = loaded.state.cursor else {
            throw RunEngineError.invalidState("Only a failed step can be retried.")
        }
        let latestAttempt = try database.runSteps(runId: loaded.id).last { $0.stepId == cursor.stepId }?.id
        let previous = loaded.state.hold?.runStepId ?? latestAttempt
        if loaded.state.hold != nil { try release(&loaded, response: "retry") }
        cursor.attempt += 1
        cursor.start = previous.map { .retry(previousRunStepID: $0) } ?? .fresh
        loaded.state.cursor = cursor
        loaded.run.status = .running
        loaded.run.endedAt = nil
        loaded.run.lastError = nil
        try commit(loaded)
        #if DEBUG
        traceControl(loaded.run, action: "retry_step")
        #endif
        launch(try loaded.id)
    }

    public func resolveLeadHold(_ run: Run, action: HoldAction) throws {
        let loaded = try load(run)
        guard let hold = loaded.state.hold, hold.isLeadFixing else {
            throw RunEngineError.invalidState("Run \(try loaded.id) has no hold for the lead to resolve.")
        }
        let allowed = hold.reason.leadActions
        guard allowed.contains(action) else {
            throw RunEngineError.invalidState("“\(action.rawValue)” doesn’t fit this hold (\(hold.reason.rawValue)). Use \(allowed.map(\.rawValue).joined(separator: " or ")).")
        }
        switch action {
        case .retry: try retryStep(run)
        case .continue: try resolveLoopLimit(run, continueOnce: true)
        case .fail where hold.reason == .loopLimit: try resolveLoopLimit(run, continueOnce: false)
        case .fail: try resolveFailure(run, retry: false)
        }
    }

    public func escalateToUser(_ run: Run, note: String?) throws {
        var loaded = try load(run)
        guard var hold = loaded.state.hold, hold.isLeadFixing else {
            throw RunEngineError.invalidState("Run \(try loaded.id) has no hold the lead is handling.")
        }
        hold.handledBy = .user
        loaded.state.hold = hold
        let body = [hold.body ?? hold.message, note.map { "The lead asks: \($0)" }].compactMap(\.self).joined(separator: "\n\n")
        let item = ChatRequest(projectId: loaded.run.projectId, runId: loaded.run.id, kind: hold.reason.requestKind, title: hold.message, body: body, createdAt: clock())
        try commit(loaded, request: item)
    }

    public func leadHeldRuns(taskId: Int64) -> [Run] {
        runs.values.filter { $0.taskId == taskId && holds[$0.id ?? -1]?.isLeadFixing == true }
    }

    public func pause(_ run: Run) async throws {
        var loaded = try load(run)
        guard loaded.run.status == .running else { throw RunEngineError.invalidState("Only a running run can be paused.") }
        loaded.run.status = .paused
        try commit(loaded)
        #if DEBUG
        traceControl(loaded.run, action: "pause")
        #endif
        await stopDriving(try loaded.id)
        try interruptInFlightSteps(runID: loaded.id)
    }

    public func resume(_ run: Run) throws {
        var loaded = try load(run)
        guard [.paused, .interrupted].contains(loaded.run.status) else {
            throw RunEngineError.invalidState("Only a paused run can be resumed.")
        }
        loaded.run.status = .running
        try commit(loaded)
        #if DEBUG
        traceControl(loaded.run, action: "resume")
        #endif
        launch(try loaded.id)
    }

    public func cancel(_ run: Run) async throws {
        var loaded = try load(run)
        guard loaded.run.isActive else { throw RunEngineError.invalidState("This run already finished.") }
        let runID = try loaded.id
        loaded.run.status = .cancelled
        loaded.run.endedAt = clock()
        loaded.state.hold = nil
        try commit(loaded)
        #if DEBUG
        traceControl(loaded.run, action: "cancel")
        #endif
        await stopDriving(runID)
        let now = clock()
        try await database.writer.write { db in
            for var step in try RunStep.filter(RunStep.Columns.runId == runID).fetchAll(db)
            where [.running, .waitingOnYou].contains(step.status) {
                step.status = .cancelled
                step.endedAt = now
                try step.update(db)
            }
            for var item in try ChatRequest.filter(ChatRequest.Columns.runId == runID).fetchAll(db)
            where item.status == .open && item.kind != .notice {
                item.status = .dismissed
                item.resolvedAt = now
                try item.update(db)
            }
        }
        await driver.cancel(loaded.run)
    }

    public func mergeDelivery(_ run: Run, method: MergeMethod) async throws {
        guard let runID = run.id, let current = try database.run(id: runID) else { throw RunEngineError.runNotFound }
        guard current.status == .succeeded, let branch = current.deliveryBranch else {
            throw RunEngineError.invalidState("Only a finished run with a delivery branch can be merged.")
        }
        guard current.mergedAt == nil else { throw RunEngineError.invalidState("This run was already merged.") }
        guard !mergingRuns.contains(runID) else { throw RunEngineError.invalidState("This run is already being merged.") }
        guard !pushingRuns.contains(runID) else { throw RunEngineError.invalidState("This run is being pushed.") }
        mergingRuns.insert(runID)
        defer { mergingRuns.remove(runID) }
        let summary: String
        do {
            summary = try await driver.mergeDelivery(current, method: method)
        } catch {
            mergeFailed?(current, error.localizedDescription)
            throw error
        }
        guard var merged = try database.run(id: runID) else { throw RunEngineError.runNotFound }
        merged.mergedAt = clock()
        merged.outcome = summary.isEmpty ? "Merged \(branch) into \(current.baseBranch ?? "the base branch")." : summary
        let updated = merged
        try await database.writer.write { db in try updated.update(db) }
        refresh(updated, state: try database.engineState(runId: runID))
    }

    public func push(_ run: Run) async throws -> String {
        guard let runID = run.id, let current = try database.run(id: runID) else { throw RunEngineError.runNotFound }
        guard current.mergedAt != nil else { throw RunEngineError.invalidState("Only a run merged into its base branch can be pushed.") }
        guard current.pushedAt == nil else { throw RunEngineError.invalidState("This run was already pushed.") }
        guard !pushingRuns.contains(runID) else { throw RunEngineError.invalidState("This run is already being pushed.") }
        guard !mergingRuns.contains(runID) else { throw RunEngineError.invalidState("This run is being merged.") }
        pushingRuns.insert(runID)
        defer { pushingRuns.remove(runID) }
        let summary = try await driver.pushBase(current)
        guard var pushed = try database.run(id: runID) else { throw RunEngineError.runNotFound }
        pushed.pushedAt = clock()
        pushed.outcome = [pushed.outcome, summary].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
        let updated = pushed
        try await database.writer.write { db in try updated.update(db) }
        refresh(updated, state: try database.engineState(runId: runID))
        return summary
    }

    public func recover() throws {
        var failures: [String] = []
        for run in try database.runs(status: [.pending, .running, .interrupted]) {
            guard let runID = run.id, drivers[runID] == nil else { continue }
            do {
                try interruptInFlightSteps(runID: runID)
                var loaded = try load(run)
                loaded.run.status = loaded.state.hold == nil ? .running : .waitingOnYou
                try commit(loaded)
                #if DEBUG
                traceControl(loaded.run, action: "recover")
                #endif
                launch(runID)
            } catch {
                failures.append("“\(run.title.isEmpty ? run.workflow : run.title)”: \(error.localizedDescription)")
            }
        }
        for run in try database.runs(status: [.waitingOnYou, .paused]) {
            guard let runID = run.id else { continue }
            do {
                refresh(run, state: try database.engineState(runId: runID))
            } catch {
                failures.append("“\(run.title.isEmpty ? run.workflow : run.title)”: \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else { throw RunEngineError.invalidState("Couldn’t recover \(failures.joined(separator: "; "))") }
    }

    @discardableResult
    public func reviveOrphanedRuns(now: Date = .now) throws -> [Int64] {
        var orphans: Set<Int64> = []
        for run in try database.runs(status: [.running]) {
            guard let runID = run.id, drivers[runID] == nil, try database.engineState(runId: runID).hold == nil else { continue }
            orphans.insert(runID)
        }
        let confirmed = orphans.intersection(suspectedOrphans).sorted()
        suspectedOrphans = orphans.subtracting(confirmed)
        var revived: [Int64] = []
        for runID in confirmed {
            try interruptInFlightSteps(runID: runID)
            let loaded = try load(runID)
            guard loaded.run.status == .running, loaded.state.hold == nil else { continue }
            try commit(loaded)
            #if DEBUG
            traceControl(loaded.run, action: "revive_orphan")
            #endif
            launch(runID)
            try postRevivalNote(loaded, now: now)
            revived.append(runID)
        }
        return revived
    }

    private func postRevivalNote(_ loaded: LoadedRun, now: Date) throws {
        let run = loaded.run
        let stepID = run.currentStep ?? loaded.state.cursor?.stepId ?? ""
        let stepTitle = loaded.workflow.step(stepID)?.displayTitle ?? stepID
        let text = "Run “\(run.title)” had stopped moving at “\(stepTitle)”, so Saturn picked it up again."
        try database.insert(LeadMessage(projectId: run.projectId, taskId: run.taskId, kind: .note, text: text, runId: try loaded.id, createdAt: now))
    }

    public func startOrphanWatchdog(interval: Duration = .seconds(30)) {
        orphanWatchdog?.cancel()
        orphanWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                _ = try? self.reviveOrphanedRuns(now: self.clock())
            }
        }
    }

    public func stopOrphanWatchdog() {
        orphanWatchdog?.cancel()
        orphanWatchdog = nil
    }

    public var isWatchingForOrphans: Bool {
        orphanWatchdog != nil
    }

    public nonisolated static let reminderPrefix = "Still waiting for you: "

    @discardableResult
    public func postApprovalReminders(now: Date = .now) throws -> [ChatRequest] {
        var posted: [ChatRequest] = []
        for run in try database.runs(status: [.waitingOnYou]) {
            guard let id = run.id, let hold = try database.engineState(runId: id).hold, hold.reason == .approval,
                  (try? workflow(for: run))?.step(hold.stepId)?.remindDaily == true else { continue }
            let items = try database.chatRequests(runId: id)
            guard let opened = items.first(where: { $0.id == hold.requestId })?.createdAt else { continue }
            let lastNudge = items.filter { $0.title.hasPrefix(Self.reminderPrefix) }.map(\.createdAt).max() ?? opened
            guard now.timeIntervalSince(lastNudge) >= 86_400 else { continue }
            let days = Int(now.timeIntervalSince(opened) / 86_400)
            posted.append(try database.createChatRequest(ChatRequest(
                projectId: run.projectId, runId: id, kind: .notice, title: Self.reminderPrefix + run.title,
                body: "“\(hold.message)” has waited \(days) day\(days == 1 ? "" : "s") for your approval.", createdAt: now
            )))
        }
        return posted
    }

    public func waitUntilIdle(runID: Int64) async {
        while let entry = drivers[runID] {
            await entry.task.value
        }
    }

    func launch(_ runID: Int64) {
        guard drivers[runID] == nil else { return }
        let token = UUID()
        let task = Task { [weak self] in
            await self?.drive(runID)
            self?.driverFinished(runID, token: token)
        }
        drivers[runID] = (token, task)
    }

    private func driverFinished(_ runID: Int64, token: UUID) {
        if drivers[runID]?.token == token { drivers[runID] = nil }
    }

    private func stopDriving(_ runID: Int64) async {
        guard let entry = drivers[runID] else { return }
        entry.task.cancel()
        await entry.task.value
    }

    private func interruptInFlightSteps(runID: Int64) throws {
        let now = clock()
        let interrupted = try database.writer.write { db in
            var ids: [(String, Int64)] = []
            for var step in try RunStep.filter(RunStep.Columns.runId == runID).filter(RunStep.Columns.status == RunStepStatus.running.rawValue).order(Column("id")).fetchAll(db) {
                step.status = .interrupted
                step.endedAt = now
                try step.update(db)
                if let id = step.id { ids.append((step.stepId, id)) }
            }
            return ids
        }
        guard !interrupted.isEmpty else { return }
        var state = try database.engineState(runId: runID)
        if var cursor = state.cursor, let last = interrupted.last(where: { $0.0 == cursor.stepId }) {
            cursor.start = .resume(interruptedRunStepID: last.1)
            state.cursor = cursor
            try database.save(state, runId: runID)
        }
    }
}

struct LoadedRun {
    var run: Run
    var state: RunEngineState
    var workflow: WorkflowDefinition

    var id: Int64 {
        get throws {
            guard let id = run.id else { throw RunEngineError.runNotFound }
            return id
        }
    }
}

extension RunEngine {
    func load(_ run: Run) throws -> LoadedRun {
        guard let id = run.id else { throw RunEngineError.runNotFound }
        return try load(id)
    }

    func load(_ runID: Int64) throws -> LoadedRun {
        guard let run = try database.run(id: runID) else { throw RunEngineError.runNotFound }
        return LoadedRun(run: run, state: try database.engineState(runId: runID), workflow: try workflow(for: run))
    }

    func requireHold(_ loaded: LoadedRun, _ reason: HoldReason) throws -> RunHold {
        guard let hold = loaded.state.hold, hold.reason == reason else { throw RunEngineError.notWaiting(reason) }
        return hold
    }

    func commit(_ loaded: LoadedRun, steps: [RunStep] = [], request inbox: ChatRequest? = nil) throws {
        let runID = try loaded.id
        let run = loaded.run
        let now = clock()
        let taskStatus = Self.taskStatus(for: run.status)
        let state = try database.writer.write { db in
            var state = loaded.state
            if let inbox {
                let request = try ChatRequest.insertAttached(inbox, db)
                state.hold?.requestId = request.id
            }
            try run.update(db)
            try db.execute(sql: "UPDATE run SET engineState = ? WHERE id = ?", arguments: [try RunEngineState.encode(state), runID])
            for step in steps { try step.update(db) }
            try db.execute(sql: "UPDATE task SET status = ?, updatedAt = ? WHERE id = ?", arguments: [taskStatus.rawValue, now, run.taskId])
            return state
        }
        refresh(run, state: state)
        #if DEBUG
        traceCommitted(loaded, steps: steps)
        #endif
    }

    func refresh(_ run: Run, state: RunEngineState) {
        guard let id = run.id else { return }
        if run.isActive {
            runs[id] = run
            holds[id] = state.hold
        } else {
            runs[id] = nil
            holds[id] = nil
            workflowCache[id] = nil
        }
    }

    static func taskStatus(for status: RunStatus) -> ChatStatus {
        switch status {
        case .pending, .running, .interrupted: .running
        case .waitingOnYou, .paused: .waitingOnYou
        case .succeeded: .done
        case .failed: .failed
        case .cancelled: .incoming
        }
    }

    func release(_ loaded: inout LoadedRun, response: String?, decision: String? = nil) throws {
        #if DEBUG
        traceReleased(loaded, response: response, decision: decision)
        #endif
        if let inboxID = loaded.state.hold?.requestId {
            try database.resolveChatRequest(id: inboxID, response: response, now: clock())
        }
        loaded.state.hold = nil
        loaded.run.status = .running
    }

    func fail(_ loaded: inout LoadedRun, message: String, response: String? = nil, steps: [RunStep] = []) throws {
        if loaded.state.hold != nil { try release(&loaded, response: response) }
        loaded.run.status = .failed
        loaded.run.lastError = message
        loaded.run.endedAt = clock()
        try commit(loaded, steps: steps)
    }

    func nextIteration(of stepId: String, runID: Int64) throws -> Int {
        (try database.runSteps(runId: runID).filter { $0.stepId == stepId }.map(\.iteration).max() ?? 0) + 1
    }

    func latestOutput(of stepId: String, runID: Int64) throws -> StepOutput {
        decodeOutput(try database.runSteps(runId: runID).last { $0.stepId == stepId && $0.status == .succeeded }?.output)
    }

    func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    func decodeOutput(_ text: String?) -> StepOutput {
        text.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) } ?? StepOutput()
    }
}
