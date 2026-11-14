import EnsembleCore
import EnsembleUI
import SwiftUI

struct AgentSessionView: View {
    @Environment(AppModel.self) private var model
    let session: LiveAgentSession
    let project: Project
    @AppStorage("preferredEditor", store: AppDefaults.store) private var preferredEditor = ""
    @Environment(\.isInWorkbench) private var isInWorkbench

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    if let run = model.exhaustedChecksRun(for: session), let hold = run.id.flatMap({ model.connection.holds[$0] }) {
                        ChecksExhaustedCard(run: run, project: project, rounds: run.checkRounds(at: hold.stepId, in: project))
                    }
                    StatusBanner(session: session)
                    TranscriptView(session: session)
                    ReadOnlyNote(session: session, project: project)
                }
                .frame(maxWidth: .infinity)
                if !isInWorkbench {
                    AgentSidePanel(session: session, project: project)
                        .frame(width: 300)
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compactControls: false)
            headerRow(compactControls: true)
        }
    }

    private func headerRow(compactControls: Bool) -> some View {
        let agent = session.agent
        return HStack(alignment: .center, spacing: 14) {
            if !isInWorkbench {
                Button {
                    model.select(nil, in: project)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Back to Agents")
                .accessibilityLabel("Back to Agents")
            }

            AgentAvatar(size: 40, appearance: RoleAppearance(role: model.role(for: agent, in: project)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(model.displayName(of: agent, in: project)).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    StatusLabel(status: model.displayStatus(of: agent), isQueued: session.isQueued, session: session).fixedSize()
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("\(model.role(for: agent, in: project)?.name ?? "Builder")\(agent.skills.isEmpty ? "" : " · \(agent.skills.joined(separator: ", "))") ·\(session.transcript.session?.model ?? agent.model.modelTitle)")
                        Text(agent.tokensAndCost).font(.system(size: 12, design: .monospaced))
                        Text("started \(Text(agent.createdAt, style: .relative)) ago")
                    }
                    .fixedSize()
                    Text(agent.tokensAndCost).font(.system(size: 12, design: .monospaced)).fixedSize()
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            }
            .frame(minWidth: 160, alignment: .leading)
            Spacer(minLength: 8)
            AgentControls(session: session, compact: compactControls)
                .fixedSize()
            Button {
                session.takeOver()
                if let worktree = agent.worktreeURL {
                    let editors = ExternalApp.installed(ExternalApp.editorCandidates)
                    (editors.first { $0.bundleIdentifier == preferredEditor } ?? editors.first)?.open(worktree)
                }
            } label: {
                if compactControls {
                    Image(systemName: "hand.raised")
                } else {
                    Label("Take Over", systemImage: "hand.raised")
                }
            }
            .buttonStyle(.pill)
            .fixedSize()
            .accessibilityLabel("Take Over")
            .help("Pauses the agent and hands its worktree to you")
            .disabled(agent.readOnly || agent.status == .takenOver || session.isStopping)
        }
    }
}

private struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    let session: LiveAgentSession

    var body: some View {
        let agent = session.agent
        if session.isSettingUp {
            banner(icon: "hammer", color: Theme.info, text: "Running the project’s setup script in this worktree. The agent starts when it finishes.") {
                ProgressView().controlSize(.small)
            }
        } else if agent.status == .failed, session.setupFailed {
            banner(icon: "xmark.octagon", color: Theme.danger, text: agent.lastError ?? "The setup script failed.") {
                Button("Retry Setup") { session.retrySetup() }
                    .buttonStyle(.primaryPill)
                    .help("Run the setup script again in this worktree")
            }
        } else {
            statusBanner(for: agent)
        }
    }

    @ViewBuilder
    private func statusBanner(for agent: Agent) -> some View {
        switch agent.status {
        case .takenOver:
            banner(icon: "hand.raised", color: Theme.info, text: "The worktree is yours. Edit freely, then hand it back and the agent picks up your changes.") {
                Button("Hand Back", action: session.handBack).buttonStyle(.primaryPill)
            }
        case .interrupted:
            banner(icon: "exclamationmark.triangle", color: Theme.warning, text: "This turn was cut off when Ensemble quit.") {
                Button("Resume", action: session.resume).buttonStyle(.primaryPill)
            }
        case .failed:
            banner(icon: "xmark.octagon", color: Theme.danger, text: agent.lastError ?? "The agent stopped unexpectedly.") {
                Button("Retry", action: session.resume).buttonStyle(.primaryPill)
            }
        case .paused:
            banner(icon: "pause.circle", color: Theme.paused, text: "Paused. Resume to continue, or send a message with new instructions.") {
                Button("Resume", action: session.resume).buttonStyle(.primaryPill)
            }
        default:
            EmptyView()
        }
    }

    private func banner(icon: String, color: Color, text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12.5)).textSelection(.enabled).lineLimit(4)
            Spacer()
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

private struct ReadOnlyNote: View {
    @Environment(AppModel.self) private var model
    let session: LiveAgentSession
    let project: Project

    var body: some View {
        let chat = model.chat(of: session.agent)
        HStack(spacing: 10) {
            Text("Workers take instructions from the Lead. To change what \(model.displayName(of: session.agent, in: project)) does, tell the Lead in the chat.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let chat {
                Button("Open the chat") { model.openChat(chat) }.buttonStyle(SecondaryPillStyle())
            }
        }
        .padding(12)
        .background(Tokens.fill, in: .rect(cornerRadius: 12, style: .continuous))
    }
}
