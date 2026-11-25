import SaturnCore
import SaturnUI
import SwiftUI

struct PaletteCommand: Identifiable {
    enum Glyph {
        case symbol(String)
        case role(RoleDefinition?)
        case project(Project)
    }

    let id: String
    let title: String
    var meta: String = ""
    var keywords: String = ""
    var glyph: Glyph
    var tint: Color = Theme.fillSelected
    var shortcut: String = ""
    var newWindow: DetailDestination?
    var matchesTitleOnly = false
    let action: () -> Void

    func matches(_ needle: String) -> Bool {
        if matchesTitleOnly { return ProjectSearch.matches(title, query: needle) }
        return title.localizedCaseInsensitiveContains(needle) || keywords.localizedCaseInsensitiveContains(needle) || meta.localizedCaseInsensitiveContains(needle)
    }
}

struct PaletteGroup: Identifiable {
    let name: String
    let commands: [PaletteCommand]

    var id: String { name }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let groups = results
        let flat = groups.flatMap(\.commands)
        ZStack(alignment: .top) {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.secondaryText)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($isFocused)
                        .onSubmit { runHighlighted(flat, newWindow: false) }
                    Text("esc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Tokens.fill2, in: .rect(cornerRadius: 5))
                }
                .padding(.horizontal, 18)
                .frame(height: 56)

                Divider().overlay(Theme.hairline)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(groups) { group in
                                Text(group.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryText)
                                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10))
                                ForEach(group.commands) { command in
                                    let index = flat.firstIndex { $0.id == command.id } ?? 0
                                    row(command, isHighlighted: index == highlighted)
                                        .id(command.id)
                                        .onHover { if $0 { highlighted = index } }
                                }
                            }
                            if flat.isEmpty {
                                Text(emptyMessage)
                                    .foregroundStyle(Theme.secondaryText)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(30)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 520)
                    .onChange(of: highlighted) {
                        if flat.indices.contains(highlighted) { proxy.scrollTo(flat[highlighted].id) }
                    }
                }

                Divider().overlay(Theme.hairline)
                HStack(spacing: 14) {
                    Text("↑ ↓ move")
                    Text("↵ open")
                    Text("⌘↵ open in new window")
                    Spacer()
                    Text("Type “>” for commands only")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: 660)
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 50, y: 20)
            .padding(.top, 90)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command palette")
            .accessibilityAddTraits(.isModal)
        }
        .defaultFocus($isFocused, true)
        .task {
            isFocused = true
            if let project = model.currentProject { await workspace.codeBrowser(for: project).refreshSources() }
        }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(flat.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            runHighlighted(flat, newWindow: true)
            return .handled
        }
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        Button {
            run(command, newWindow: false)
        } label: {
            HStack(spacing: 12) {
                glyph(command)
                HStack(spacing: 8) {
                    Text(highlightedTitle(command.title)).fontWeight(.semibold).lineLimit(1)
                    if !command.meta.isEmpty {
                        Text(command.meta).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !command.shortcut.isEmpty {
                    Text(command.shortcut).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(isHighlighted ? Theme.accent.opacity(0.32) : .clear, in: .rect(cornerRadius: 11, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func glyph(_ command: PaletteCommand) -> some View {
        switch command.glyph {
        case .role(let role):
            AgentAvatar(size: 24, appearance: RoleAppearance(role: role))
        case .project(let project):
            ProjectTile(project: project, size: 24)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(command.tint, in: .rect(cornerRadius: 7, style: .continuous))
        }
    }

    private func highlightedTitle(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        let needle = searchText
        if !needle.isEmpty, let range = text.range(of: needle, options: .caseInsensitive) {
            text[range].foregroundColor = Color(hex: 0x9CC6FF)
        }
        return text
    }

    private var isCommandsOnly: Bool {
        query.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private var searchText: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return (isCommandsOnly ? String(trimmed.dropFirst()) : trimmed).trimmingCharacters(in: .whitespaces)
    }

    private var placeholder: String {
        model.paletteMode == .agents ? "Go to an agent" : "Search chats, or type a command…"
    }

    private var emptyMessage: String {
        if model.paletteMode == .agents { return "No agents match “\(searchText)”." }
        if isCommandsOnly || model.currentProject == nil { return "No matching commands." }
        return "No matches. Press ↵ to send “\(searchText)” to the Lead as a new chat."
    }

    private var results: [PaletteGroup] {
        let source: [PaletteGroup]
        if model.paletteMode == .agents {
            source = [PaletteGroup(name: "Agents", commands: agentCommands)]
        } else if isCommandsOnly {
            source = menuGroups
        } else {
            source = [
                PaletteGroup(name: searchText.isEmpty ? "Recent chats" : "Chats", commands: chatCommands),
                PaletteGroup(name: "Projects", commands: projectCommands),
                PaletteGroup(name: "Runs", commands: runCommands),
                PaletteGroup(name: "Actions", commands: actionCommands),
                PaletteGroup(name: "Agents", commands: agentCommands),
                PaletteGroup(name: "Go to", commands: goToCommands),
            ] + (searchText.isEmpty ? [] : [PaletteGroup(name: "Files", commands: fileCommands)]) + menuGroups
        }
        let needle = searchText
        return source.compactMap { group in
            let matches = needle.isEmpty ? group.commands : group.commands.filter { $0.matches(needle) }
            let limited = group.name == "Files" || group.name.hasSuffix("chats") || group.name == "Chats" ? Array(matches.prefix(8)) : matches
            return limited.isEmpty ? nil : PaletteGroup(name: group.name, commands: limited)
        }
    }

    private var workspace: DaemonWorkspace { model.currentWorkspace }

    private func place(_ project: Project, on workspace: DaemonWorkspace) -> String {
        workspace.isRemote ? "\(project.name) · \(workspace.displayName)" : project.name
    }

    private var chatCommands: [PaletteCommand] {
        let summaries = model.chatSummaries()
        return (summaries.open + summaries.closed).compactMap { summary in
            guard let workspace = model.workspace(for: summary.daemon) else { return nil }
            return PaletteCommand(
                id: "chat-\(summary.id)", title: summary.chat.title,
                meta: "\(place(summary.project, on: workspace)) · \(ChatTime.label(summary.lastActivity)) · \(summary.stage.title)",
                keywords: summary.chat.body + " " + workspace.displayName, glyph: .symbol("bubble.left"), tint: Tokens.fill2
            ) { workspace.openChat(summary.chat) }
        }
    }

    private var runCommands: [PaletteCommand] {
        model.allOpenProjects.flatMap { workspace, project -> [PaletteCommand] in
            guard let projectID = project.id else { return [] }
            let active = workspace.connection.activeRuns(projectID: projectID)
            let recent = ((try? workspace.database.runs(projectId: projectID)) ?? []).sorted { $0.startedAt > $1.startedAt }.prefix(5)
            var seen = Set<Int64>()
            return (active + recent).compactMap { run in
                guard let id = run.id, seen.insert(id).inserted else { return PaletteCommand?.none }
                let live = run
                let step = live.currentStep.flatMap { stepID in workspace.config(for: project).workflow(live.workflow)?.step(stepID)?.displayTitle }
                let state = live.isActive ? step : live.status.rawValue.replacingOccurrences(of: "_", with: " ")
                let meta = [place(project, on: workspace), state, live.costUSD > 0 ? String(format: "$%.2f", live.costUSD) : nil].compactMap(\.self).joined(separator: " · ")
                return PaletteCommand(
                    id: "run-\(workspace.id)-\(id)", title: live.title, meta: meta, glyph: .symbol("play.fill"),
                    tint: Color(hex: 0x1F5FD1), newWindow: .run(project: workspace.ref(projectID), run: id)
                ) { workspace.showRun(live) }
            }
        }
    }

    private var actionCommands: [PaletteCommand] {
        let action = Color(hex: 0x0A84FF, opacity: 0.5)
        guard let project = model.currentProject else {
            return [PaletteCommand(id: "new-project", title: "New Project…", glyph: .symbol("plus"), tint: action, shortcut: "⌘N") { model.newProject() }]
                + projectActionCommands(tint: action)
        }
        let lead: RoleDefinition? = workspace.leadRole(in: project)
        let config = workspace.config(for: project)
        var commands = [
            PaletteCommand(id: "new-chat", title: "New chat", meta: lead.map { "with \($0.name)" } ?? "", glyph: .symbol("plus"), tint: action, shortcut: "⌘N") {
                DispatchQueue.main.async { model.requestNewChat() }
            },
            PaletteCommand(id: "add-project", title: "Add project…", glyph: .symbol("folder.badge.plus"), tint: action) { model.isOpenPanelPresented = true },
            PaletteCommand(id: "appearance", title: model.appearance == .light ? "Switch to dark appearance" : "Switch to light appearance", glyph: .symbol("circle.lefthalf.filled"), tint: action) {
                model.appearance = model.appearance == .light ? .dark : .light
            },
            PaletteCommand(id: "encode", title: "Encode a correction…", meta: "AGENTS.md, check or protected path", glyph: .symbol("arrow.triangle.2.circlepath"), tint: action) {
                workspace.openSettings(.learnedRules, in: project)
            },
            PaletteCommand(id: "spawn", title: "Spawn agent…", glyph: .symbol("plus"), tint: action, shortcut: "⇧⌘A") { model.spawnAgent() },
            PaletteCommand(id: "pause-all", title: "Pause all agents", meta: project.name, glyph: .symbol("pause.fill"), tint: action, shortcut: "⇧⌘P") {
                workspace.pauseAllAgents(in: project)
            },
        ]
        if workspace.hasPendingPins(in: project) {
            commands.insert(PaletteCommand(id: "pins", title: "Approve pins", meta: "Changes", glyph: .symbol("pin.fill"), tint: action) {
                workspace.setTab(.changes, for: project)
            }, at: 2)
        }
        if let workflow = config.workflow(config.preferences.defaultWorkflow ?? "") ?? config.workflows.first {
            commands.insert(PaletteCommand(id: "test-run", title: "Test run \(workflow.displayName)", meta: "dry run", glyph: .symbol("play"), tint: action) {
                workspace.testRun(workflow, in: project)
            }, at: min(commands.count, 4))
        }
        return commands + projectActionCommands(tint: action)
    }

    private var projectsCurrentFirst: [(workspace: DaemonWorkspace, project: Project)] {
        let all = model.allOpenProjects
        let current = all.filter { $0.workspace.ref(of: $0.project) == model.currentRef }
        return current + all.filter { $0.workspace.ref(of: $0.project) != model.currentRef }
    }

    private func paletteID(_ kind: String, _ workspace: DaemonWorkspace, _ project: Project) -> String {
        "\(kind)-\(workspace.id.uuidString)-\(project.id ?? -1)"
    }

    private func projectActionCommands(tint: Color) -> [PaletteCommand] {
        projectsCurrentFirst.flatMap { workspace, project -> [PaletteCommand] in
            let meta = place(project, on: workspace)
            let locate = project.isRemote
                ? PaletteCommand(id: paletteID("copy-ssh", workspace, project), title: "Copy SSH path", meta: meta, glyph: .symbol("doc.on.doc"), tint: tint) {
                    workspace.copyToPasteboard("\(project.location):\(project.path)")
                }
                : PaletteCommand(id: paletteID("reveal", workspace, project), title: "Reveal in Finder", meta: meta, glyph: .symbol("folder"), tint: tint) {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                }
            return [
                PaletteCommand(id: paletteID("new-chat-in", workspace, project), title: "New chat in \(project.name)", meta: meta, glyph: .symbol("square.and.pencil"), tint: tint) {
                    workspace.startNewChat(in: project)
                },
                locate,
                PaletteCommand(id: paletteID("remove", workspace, project), title: "Remove \(project.name) from Saturn…", meta: meta, glyph: .symbol("minus.circle"), tint: tint) {
                    workspace.close(project)
                },
            ]
        }
    }

    private var agentCommands: [PaletteCommand] {
        let projects = model.currentProject.map { [$0] } ?? workspace.openProjects
        return projects.flatMap { project in
            workspace.agentSessions(in: project)
                .filter { $0.agent.archivedAt == nil }
                .map { session in
                    let role = workspace.config(for: project).role(session.agent.role)
                    let detail = session.agent.task.isEmpty ? (role?.name ?? session.agent.role) + (session.agent.isPinned ? " · pinned" : "") : session.agent.task
                    return PaletteCommand(
                        id: "agent-\(session.id)", title: workspace.displayName(of: session.agent, in: project), meta: detail,
                        keywords: role?.name ?? "", glyph: .role(role),
                        newWindow: workspace.ref(of: project).map { .agent(project: $0, agent: session.id) }
                    ) { workspace.openAgent(session, in: project) }
                }
        }
    }

    private var goToCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []
        for (workspace, project) in projectsCurrentFirst {
            let meta = place(project, on: workspace)
            commands += ProjectTab.sidebarOrder.map { tab in
                PaletteCommand(id: paletteID("go-\(tab.rawValue)", workspace, project), title: tab.paletteTitle, meta: meta, keywords: tab.title, glyph: .symbol(tab.paletteSymbol)) {
                    if let tool = MainTool(tab: tab) { workspace.open(tool, in: project) } else { workspace.expand(project) }
                }
            }
            commands += SettingsSection.allCases.map { section in
                PaletteCommand(id: paletteID("settings-\(section.rawValue)", workspace, project), title: "Settings › \(section.title)", meta: meta, glyph: .symbol(section.symbol)) {
                    workspace.openSettings(section, in: project)
                }
            }
        }
        commands += [
            PaletteCommand(id: "go-usage", title: "Usage", meta: String(format: "$%.2f this week · $%.2f this month", model.weeklySpend, model.monthlySpend), glyph: .symbol("chart.bar")) { model.open(.usage) },
        ]
        return commands
    }

    private var projectCommands: [PaletteCommand] {
        projectsCurrentFirst.compactMap { workspace, project in
            guard let ref = workspace.ref(of: project) else { return nil }
            let location = workspace.isRemote ? workspace.displayName : "This Mac"
            let path = workspace.isRemote ? project.path : project.path.abbreviatingHome
            return PaletteCommand(
                id: "project-\(ref.daemon)-\(ref.id)", title: project.name, meta: "\(location) · \(path)",
                glyph: .project(project), matchesTitleOnly: true
            ) { workspace.openProject(project) }
        }
    }

    private var fileCommands: [PaletteCommand] {
        guard let project = model.currentProject, let ref = workspace.ref(of: project) else { return [] }
        let files = workspace.codeBrowser(for: project).snapshot?.files ?? []
        let needle = searchText
        return files
            .filter { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(needle) }
            .prefix(8)
            .map { path in
                PaletteCommand(
                    id: "file-\(path)", title: (path as NSString).lastPathComponent, meta: path, glyph: .symbol("doc.text"),
                    newWindow: .file(project: ref, path: path)
                ) { workspace.openFile(path, in: project) }
            }
    }

    private var menuGroups: [PaletteGroup] {
        let context = CommandContext(model: model, openWindow: openWindow)
        return CommandRegistry.menuBar.compactMap { menu in
            let commands = CommandRegistry.shared.commands(in: menu).flatMap(\.self).filter { $0.isEnabled(context) }
            guard !commands.isEmpty else { return nil }
            return PaletteGroup(name: "\(menu) menu", commands: commands.map { command in
                PaletteCommand(
                    id: "m-\(command.id)", title: command.title, meta: menu, keywords: command.keywords,
                    glyph: .symbol("chevron.right"), tint: Theme.fillSelected, shortcut: KeyBindings.shared.shortcut(for: command)?.displayString ?? ""
                ) {
                    DispatchQueue.main.async { command.perform(context) }
                }
            })
        }
    }

    private func runHighlighted(_ flat: [PaletteCommand], newWindow: Bool) {
        if flat.indices.contains(highlighted) {
            run(flat[highlighted], newWindow: newWindow)
        } else if flat.isEmpty, model.paletteMode == .everything, !isCommandsOnly, !searchText.isEmpty {
            let text = searchText
            dismiss()
            model.sendToLead(text)
        }
    }

    private func run(_ command: PaletteCommand, newWindow: Bool) {
        dismiss()
        if newWindow, let destination = command.newWindow {
            openWindow(id: WindowID.detail, value: destination)
        } else {
            command.action()
        }
    }

    private func dismiss() {
        model.isPalettePresented = false
        model.paletteMode = .everything
    }
}

extension ProjectTab {
    var paletteTitle: String { self == .code ? "Source" : title }

    var paletteSymbol: String {
        switch self {
        case .lead: "bubble.left.and.bubble.right"
        case .agents: "person.2"
        case .changes: "arrow.triangle.branch"
        case .workflows: "flowchart"
        case .settings: "gearshape"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}
