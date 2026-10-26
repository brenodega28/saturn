import EnsembleCore
import EnsembleUI
import SwiftUI

struct AgentSessionView: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    @AppStorage("preferredEditor") private var preferredEditor = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    StatusBanner(session: session)
                    TranscriptView(session: session)
                    Composer(session: session)
                        .disabled(model.agents.isSettingUp(session))
                }
                .frame(maxWidth: .infinity)
                AgentSidePanel(session: session, project: project)
                    .frame(width: 300)
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
            Button {
                model.select(nil, in: project)
            } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Back to Agents")
            .accessibilityLabel("Back to Agents")

            AgentAvatar(size: 40, appearance: RoleAppearance(role: model.role(for: agent, in: project)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(model.displayName(of: agent, in: project)).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    StatusLabel(status: model.displayStatus(of: agent), isQueued: session.isQueued, session: session).fixedSize()
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("\(model.role(for: agent, in: project)?.name ?? "Claude Code") · \(session.transcript.session?.model ?? agent.model.modelTitle)")
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
    let session: AgentSession

    var body: some View {
        let agent = session.agent
        if model.agents.isSettingUp(session) {
            banner(icon: "hammer", color: Theme.info, text: "Running the project’s setup script in this worktree. The agent starts when it finishes.") {
                ProgressView().controlSize(.small)
            }
        } else if agent.status == .failed, model.agents.setupFailed(session) {
            banner(icon: "xmark.octagon", color: Theme.danger, text: agent.lastError ?? "The setup script failed.") {
                Button("Retry Setup") { model.agents.retrySetup(session) }
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

private struct Composer: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let sendTarget = PendingSendTarget.session(session.id)
        VStack(alignment: .leading, spacing: 8) {
            PendingSendChip(target: sendTarget, onUndo: restore)
            if !session.queuedMessages.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11))
                    Text("\(session.queuedMessages.count) queued for when this turn ends")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(model.displayName(of: session.agent))", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        send()
                        return .handled
                    }
                    .task(id: session.id) { isFocused = true }
                    .padding(.vertical, 6)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        }
        .animation(.snappy(duration: 0.2), value: model.pendingSends.holds(for: sendTarget).count)
    }

    private func send() {
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        model.holdSessionMessage(message, to: session)
    }

    private func restore(_ message: PendingMessage) {
        text = PendingMessage(text: text).appending(message).text
        isFocused = true
    }
}
