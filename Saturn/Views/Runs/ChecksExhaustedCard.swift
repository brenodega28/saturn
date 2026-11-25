import AppKit
import SaturnCore
import SaturnUI
import SwiftUI

struct ChecksExhaustedCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let run: Run
    let project: Project
    let rounds: Int
    var reload: () -> Void = {}
    @State private var isGivingGuidance = false
    @State private var guidance = ""

    var body: some View {
        let builders = workspace.checkBuilders(of: run, in: project)
        let names = builders.map { workspace.displayName(of: $0.agent, in: project) }
        VStack(alignment: .leading, spacing: 10) {
            Label("Checks still failing after \(rounds) round\(rounds == 1 ? "" : "s")", systemImage: "tray.full")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text("\(names.isEmpty ? "The builders are" : ListFormatter.localizedString(byJoining: names) + (names.count == 1 ? " is" : " are")) stopped and the failing output is in this chat. Nothing unverified reached Changes.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if isGivingGuidance {
                NoteField(
                    prompt: "What should they try? They’ll get this, then the checks run again.",
                    note: $guidance,
                    sendTitle: "Send and Retry",
                    cancel: { isGivingGuidance = false },
                    send: sendGuidance
                )
            } else {
                HStack(spacing: 8) {
                    Button("Give Guidance") { isGivingGuidance = true }
                        .buttonStyle(PillButtonStyle(.primary, height: 30))
                        .help("Tell the agents what to try, then run the checks again")
                    Button("Take Over") { workspace.takeOver(builders.first) }
                        .buttonStyle(PillButtonStyle(height: 30))
                        .disabled(builders.first?.agent.worktreeURL == nil)
                        .help("Open the worktree in Terminal and fix it yourself")
                    Button("Retry Once More") {
                        workspace.resolveFailure(run, retry: true)
                        reload()
                    }
                    .buttonStyle(PillButtonStyle(height: 30))
                    .help("Give the agents another round of check results")
                    Button("End, Keep Branch") {
                        workspace.resolveFailure(run, retry: false)
                        reload()
                    }
                    .buttonStyle(PillButtonStyle(height: 30))
                    .help("Stop the run here. The branches stay so you can pick them up later")
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.09), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.danger.opacity(0.28)))
        .accessibilityElement(children: .contain)
    }

    private func sendGuidance() {
        let note = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        workspace.giveChecksGuidance(note, run: run, in: project)
        guidance = ""
        isGivingGuidance = false
        reload()
    }
}

extension Run {
    @MainActor
    func checkRounds(at stepID: String, in project: Project) -> Int {
        snapshotWorkflow?.step(stepID)?.maxRounds ?? ProjectConfigLoader.load(repository: project.filesRoot).checks?.maxRounds ?? ChecksConfig.defaultMaxRounds
    }
}

extension DaemonWorkspace {
    func exhaustedChecksRun(for session: LiveAgentSession) -> Run? {
        guard let runID = session.agent.runId, !session.agent.readOnly, let hold = connection.holds[runID],
              let run = (try? database.run(id: runID)) ?? nil,
              hold.isChecksExhausted(in: run.snapshotWorkflow) else { return nil }
        return run
    }

    func checkBuilders(of run: Run, in project: Project) -> [LiveAgentSession] {
        guard let runID = run.id, let projectID = project.id else { return [] }
        return ((try? connection.runSessions(runId: runID, projectId: projectID)) ?? []).filter { !$0.agent.readOnly }
    }

    func takeOver(_ session: LiveAgentSession?) {
        if let session, let worktree = session.agent.worktreeURL, isRemote(session.agent) {
            openRemoteShell(at: worktree, forAgent: session.agent)
            return
        }
        guard let worktree = session?.agent.worktreeURL,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([worktree], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func giveChecksGuidance(_ note: String, run: Run, in project: Project) {
        let builders = checkBuilders(of: run, in: project)
        for session in builders {
            session.send("The checks still fail and the user has guidance for you:\n\n\(note)\n\nApply it and commit. Saturn runs the checks again when you’re done.")
        }
        Task { [weak self] in
            let deadline = Date.now.addingTimeInterval(30 * 60)
            while Date.now < deadline, builders.contains(where: { $0.isRunning || $0.isQueued }) {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self else { return }
            resolveFailure(run, retry: true)
        }
    }
}
