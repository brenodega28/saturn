import EnsembleCore
import EnsembleUI
import SwiftUI
import UniformTypeIdentifiers

struct LeadComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let request: Chat?
    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var isDropTargeted = false
    @State private var files: [String] = []

    var body: some View {
        let lead = workspace.chatLeadRole(in: project)
        let sendTarget = workspace.leadSendTarget(for: request, in: project)
        VStack(alignment: .leading, spacing: 8) {
            suggestions
            composer(lead: lead)
        }
        .restoresReturnedSends(for: sendTarget, perform: restore)
        .task(id: project.id) { files = await workspace.projectFiles(project) }
        .onChange(of: model.composerPrefill, initial: true) { _, prefill in
            guard let prefill, request == nil else { return }
            text = prefill
            model.composerPrefill = nil
            model.composerFocusToken += 1
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        switch ComposerCompletion.token(in: text) {
        case .command(let query):
            let commands = ComposerCompletion.commands(matching: query)
            if !commands.isEmpty {
                SuggestionList(title: "Commands", items: commands.map { ($0.name, $0.summary) }) { text = ComposerCompletion.completing(text, with: $0) }
            }
        case .file(let query):
            let matches = ComposerCompletion.files(files, matching: query)
            if !matches.isEmpty {
                SuggestionList(title: query.isEmpty ? "Files" : "Files matching “\(query)”", items: matches.map { ($0, "") }) { text = ComposerCompletion.completing(text, with: $0) }
            }
        case nil:
            EmptyView()
        }
    }

    private func composer(lead: RoleDefinition?) -> some View {
        let isBusy = workspace.isLeadBusy(request)
        return VStack(alignment: .leading, spacing: 10) {
            ChatComposerInput(
                text: $text,
                attachments: $attachments,
                isDropTargeted: $isDropTargeted,
                placeholder: placeholder(isBusy: isBusy),
                accessibilityLabel: request == nil ? "Describe what you need" : "Message the Lead",
                onSubmit: { send(lead: lead) }
            )
            HStack(spacing: 10) {
                Button(action: attach) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Tokens.text2)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Attach images or text files")
                .accessibilityLabel("Attach")
                Spacer()
                WorkflowMenu(project: project, chat: request)
                ModelMenu(project: project, chat: request)
                if isBusy, let request {
                    Button { workspace.stopLead(request) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11))
                            .foregroundStyle(Tokens.text)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(Tokens.hair2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop the Lead")
                    .accessibilityLabel("Stop the Lead")
                }
                Button(action: { send(lead: lead) }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Tokens.primaryForeground)
                        .frame(width: 32, height: 32)
                        .background(Tokens.primaryBackground, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend(lead: lead))
                .opacity(canSend(lead: lead) ? 1 : 0.4)
                .keyboardShortcut(.return, modifiers: .command)
                .help(isBusy ? "Queue message (⌘↩)" : "Send (⌘↩)")
                .accessibilityLabel(isBusy ? "Queue message" : "Send")
            }
            .font(.system(size: 13))
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 14))
        .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.composer, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.composer, style: .continuous).strokeBorder(Tokens.hair2))
        .shadow(color: Tokens.shadow.opacity(0.15), radius: 8, y: 4)
        .chatAttachmentDrop($attachments, isTargeted: $isDropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message the Lead")
    }

    private func placeholder(isBusy: Bool) -> String {
        if request == nil { return "Describe what you need…" }
        if request?.isClosed == true { return "Send a message to reopen…" }
        if isBusy { return "The Lead is working. Messages queue until it finishes." }
        return "Message the Lead. @ for files, / for commands"
    }

    private func canSend(lead: RoleDefinition?) -> Bool {
        (lead != nil || request.flatMap(workspace.leadSession(for:)) != nil)
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send(lead: RoleDefinition?) {
        guard canSend(lead: lead) else { return }
        if let command = ChatCommand.parse(text), command.runsLocally, attachments.isEmpty {
            text = ""
            workspace.runLocalCommand(command, in: request)
            return
        }
        let message = PendingMessage(text: text, attachments: attachments)
        text = ""
        attachments = []
        workspace.deliverLeadMessage(message, lead: lead, to: request, in: project)
    }

    private func restore(_ message: PendingMessage) {
        let merged = PendingMessage(text: text, attachments: attachments).appending(message)
        text = merged.text
        attachments = merged.attachments
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .plainText, .sourceCode, .json]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let data = try? Data(contentsOf: url) {
                attachments.append(.image(id: UUID(), mediaType: type.preferredMIMEType ?? "image/png", fileName: url.lastPathComponent, data: data))
            } else if let contents = try? String(contentsOf: url, encoding: .utf8) {
                attachments.append(.pastedText(id: UUID(), index: ChatAttachment.nextPasteIndex(after: attachments), text: contents))
            }
        }
    }
}

private struct SuggestionList: View {
    let title: String
    let items: [(String, String)]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Tokens.text2).padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
            ForEach(items, id: \.0) { item in
                Button { pick(item.0) } label: {
                    HStack(spacing: 10) {
                        Text(item.0).font(Tokens.mono(12.5)).foregroundStyle(Tokens.text)
                        if !item.1.isEmpty { Text(item.1).font(.system(size: 12)).foregroundStyle(Tokens.text2) }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Tokens.menu, in: .rect(cornerRadius: Tokens.Radius.popover, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous).strokeBorder(Tokens.hair2))
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct WorkflowMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat?

    var body: some View {
        let workflows = workspace.config(for: project).workflows
        let current = workspace.chatWorkflow(for: chat, in: project)
        Menu {
            Section("Workflow for this chat") {
                ForEach(workflows) { workflow in
                    Button {
                        workspace.setWorkflow(workflow.id, for: chat, in: project)
                    } label: {
                        if workflow.id == current { Label(workflow.displayName, systemImage: "checkmark") } else { Text(workflow.displayName) }
                    }
                }
            }
        } label: {
            Text(workflows.first { $0.id == current }?.displayName ?? "Workflow").foregroundStyle(Tokens.text2)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Workflow for this chat")
    }
}

private struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let chat: Chat?

    var body: some View {
        let current = workspace.leadModel(for: chat, in: project)
        let effort = workspace.leadEffort(for: chat, in: project)
        Menu {
            Section("Lead model") {
                ForEach(AppModel.leadModels, id: \.id) { option in
                    Button {
                        workspace.setLead(model: option.id, effort: effort, for: chat, in: project)
                    } label: {
                        if option.id == current { Label("\(option.title) · \(option.detail)", systemImage: "checkmark") } else { Text("\(option.title) · \(option.detail)") }
                    }
                }
            }
            Section("Effort") {
                ForEach(LeadEffort.allCases, id: \.self) { level in
                    Button {
                        workspace.setLead(model: current, effort: level, for: chat, in: project)
                    } label: {
                        if level == effort { Label(level.title, systemImage: "checkmark") } else { Text(level.title) }
                    }
                }
            }
        } label: {
            Text("\(current.modelTitle) \(effort.title)").foregroundStyle(Tokens.text)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("The Lead’s model and effort for this chat")
    }
}

extension LeadEffort {
    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}
