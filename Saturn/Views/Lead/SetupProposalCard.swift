import SaturnCore
import SaturnUI
import SwiftUI

struct SetupProposalCard: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let card: LeadMessage
    let project: Project
    @State private var expanded: Set<String> = []
    @State private var isApplying = false

    var body: some View {
        let proposal = card.setupProposal
        let files = proposal?.files(in: project.filesRoot) ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Proposed setup").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
                if let proposal {
                    Text(proposal.workflow.name).font(.system(size: 12)).foregroundStyle(Tokens.link)
                }
                Spacer(minLength: 0)
                statusLabel
            }
            if let proposal {
                Text(summary(of: proposal)).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in
                        SetupFileRow(file: file, showsMarker: card.status == .open, isExpanded: expanded.contains(file.path)) {
                            withAnimation(.snappy(duration: 0.2)) {
                                if expanded.remove(file.path) == nil { expanded.insert(file.path) }
                            }
                        }
                    }
                }
            } else {
                Text("Saturn couldn’t read this setup.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            if card.status == .open, proposal != nil {
                HStack(spacing: 8) {
                    Text("Files land uncommitted in your working tree.").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                    Spacer(minLength: 0)
                    Button("Dismiss") { workspace.dismissSetupProposal(card) }
                        .buttonStyle(SecondaryPillStyle())
                        .help("Don’t write these files; keep talking to the lead")
                    Button("Apply") {
                        isApplying = true
                        Task {
                            await workspace.applySetupProposal(card, in: project)
                            isApplying = false
                        }
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(isApplying)
                    .help("Write every file listed above")
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(card.status == .open ? Tokens.hair2 : Tokens.hair))
    }

    private func summary(of proposal: SetupProposal) -> String {
        let agents = "\(proposal.agents.count) agent profile\(proposal.agents.count == 1 ? "" : "s")"
        let workflow = proposal.makeDefault ? "a default workflow" : "a workflow"
        return "Mission, \(agents) and \(workflow), with specs in \(proposal.specFolder)/"
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch card.status {
        case .applied: Text("Applied").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.done)
        case .dismissed: Text("Dismissed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
        default: EmptyView()
        }
    }
}

private struct SetupFileRow: View {
    let file: SetupFile
    let showsMarker: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 10)
                    Text(file.path)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsMarker {
                        Text(file.overwrites ? "overwrite" : "new")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(file.overwrites ? Color.orange : Tokens.done)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the preview" : "Preview what Saturn will write")
            if isExpanded {
                ScrollView {
                    Text(file.contents)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Tokens.hair.opacity(0.4), in: .rect(cornerRadius: 8, style: .continuous))
                .padding(.leading, 16)
            }
        }
    }
}
