import EnsembleCore
import Foundation

extension AppModel {
    func startActivityRecorder() {
        Task { [weak self] in
            var previous = ActivitySnapshot()
            var seenCheckSteps: Set<Int64> = []
            var tick = 0
            while let self, !Task.isCancelled {
                let snapshot = self.activitySnapshot(previous: previous)
                self.activityLog.append(ActivityDiff.events(from: previous, to: snapshot, at: .now))
                self.activityLog.append(self.newCheckResults(seen: &seenCheckSteps))
                previous = snapshot
                if tick % 5 == 0 { await self.refreshListeningPorts() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func activitySnapshot(previous: ActivitySnapshot) -> ActivitySnapshot {
        var runs: [Int64: ActivitySnapshot.RunState] = [:]
        var ids = Set(engine.runs.keys)
        for (id, state) in previous.runs where ProjectSignals.activeStatuses.contains(state.status) {
            ids.insert(id)
        }
        for id in ids {
            guard let run = run(withID: id) else { continue }
            runs[id] = ActivitySnapshot.RunState(
                projectId: run.projectId, title: run.displayTitle, status: run.status,
                step: currentStepTitle(of: run), hold: engine.holds[id]?.message, error: run.lastError
            )
        }
        var agentStates: [Int64: ActivitySnapshot.AgentState] = [:]
        for project in openProjects {
            guard let projectID = project.id else { continue }
            for session in agentSessions(in: project) {
                let tools: [ActivitySnapshot.ToolState] = session.transcript.entries.suffix(60).compactMap { entry in
                    guard case .tool(let tool) = entry.content, tool.isFinished else { return nil }
                    return ActivitySnapshot.ToolState(id: tool.id, name: tool.name, target: tool.target(relativeTo: session.agent.worktreePath ?? project.url.path), isError: tool.isError)
                }
                let stepTitle = session.agent.step.flatMap { step in
                    session.agent.runId.flatMap(run(withID:)).flatMap(runWorkflow).map { RunTimeline.title(ofStep: step, in: $0) } ?? step
                }
                agentStates[session.id] = ActivitySnapshot.AgentState(
                    projectId: projectID, name: displayName(of: session.agent, in: project), status: displayStatus(of: session.agent),
                    runId: session.agent.runId, step: stepTitle, finishedTools: tools, error: session.agent.lastError
                )
            }
        }
        return ActivitySnapshot(runs: runs, agents: agentStates)
    }

    private func newCheckResults(seen: inout Set<Int64>) -> [LogEntry] {
        var entries: [LogEntry] = []
        for run in engine.runs.values {
            guard let runID = run.id else { continue }
            for step in (try? database.runSteps(runId: runID)) ?? [] {
                guard let id = step.id, !seen.contains(id), step.status != .running else { continue }
                seen.insert(id)
                guard let reports = ProjectSignals.output(of: step)?.checks, !reports.isEmpty else { continue }
                let title = runWorkflow(run).map { RunTimeline.title(ofStep: step.stepId, in: $0) } ?? step.stepId
                for report in reports {
                    let results = report.results.map { result in
                        "\(result.name) \(result.passed ? "✓" : "✗") \(result.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
                    }
                    entries.append(LogEntry(
                        date: step.endedAt ?? .now, level: report.passed ? .info : .error, source: "checks",
                        projectId: run.projectId, runId: runID, step: title,
                        message: "\(report.agentName ?? "checks") round \(report.round): " + results.joined(separator: " · ")
                    ))
                }
            }
        }
        return entries
    }

    func refreshListeningPorts() async {
        let ports = openProjects.flatMap { agentSessions(in: $0).compactMap(\.agent.port) }
        guard !ports.isEmpty else {
            listeningPorts = []
            return
        }
        let arguments = ["-nP", "-sTCP:LISTEN"] + ports.flatMap { ["-iTCP:\($0)"] } + ["-Fn"]
        let result = try? await runner.run(URL(filePath: "/usr/sbin/lsof"), arguments)
        let output = result?.standardOutput ?? ""
        listeningPorts = Set(ports.filter { port in output.contains(":\(port)\n") || output.hasSuffix(":\(port)") })
    }

    var backgroundActivity: [ActivityEntry] {
        WorkbenchRegistry.shared.activitySources.flatMap { $0.entries(self) }
    }
}
