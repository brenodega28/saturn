import EnsembleCore
import EnsembleUI
import SwiftUI

struct PaletteCommand: Identifiable {
    enum Glyph {
        case symbol(String)
        case role(RoleDefinition?)
    }

    let id: String
    let title: String
    var meta: String = ""
    var keywords: String = ""
    var glyph: Glyph
    var tint: Color = Theme.fillSelected
    var shortcut: String = ""
    var newWindow: DetailDestination?
    let action: () -> Void
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
                        .background(Color.white.opacity(0.1), in: .rect(cornerRadius: 5))
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
            if let project = model.currentProject { await model.codeBrowser(for: project).refreshSources() }
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
        model.paletteMode == .agents ? "Go to an agent" : "Search runs, agents, files, or run a command"
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
                PaletteGroup(name: "Runs", commands: runCommands),
                PaletteGroup(name: "Actions", commands: actionCommands),
                PaletteGroup(name: "Agents", commands: agentCommands),
                PaletteGroup(name: "Go to", commands: goToCommands),
            ] + (searchText.isEmpty ? [] : [PaletteGroup(name: "Files", commands: fileCommands)]) + menuGroups
        }
        let needle = searchText
        return source.compactMap { group in
            let matches = needle.isEmpty ? group.commands : group.commands.filter {
                $0.title.localizedCaseInsensitiveContains(needle) || $0.keywords.localizedCaseInsensitiveContains(needle) || $0.meta.localizedCaseInsensitiveContains(needle)
            }
            let limited = group.name == "Files" ? Array(matches.prefix(8)) : matches
            return limited.isEmpty ? nil : PaletteGroup(name: group.name, commands: limited)
        }
    }

    private var runCommands: [PaletteCommand] {
        model.openProjects.flatMap { project -> [PaletteCommand] in
            guard let projectID = project.id else { return [] }
            let active = model.engine.activeRuns(projectID: projectID)
            let recent = ((try? model.database.runs(projectId: projectID)) ?? []).sorted { $0.startedAt > $1.startedAt }.prefix(5)
            var seen = Set<Int64>()
            return (active + recent).compactMap { run in
                guard let id = run.id, seen.insert(id).inserted else { return nil }
                let live = model.engine.runs[id] ?? run
                let step = live.currentStep.flatMap { stepID in model.config(for: project).workflow(live.workflow)?.step(stepID)?.displayTitle }
                let state = live.isActive ? step : live.status.rawValue.replacingOccurrences(of: "_", with: " ")
                let meta = [project.name, state, live.costUSD > 0 ? String(format: "$%.2f", live.costUSD) : nil].compactMap(\.self).joined(separator: " · ")
                return PaletteCommand(
                    id: "run-\(id)", title: live.title, meta: meta, glyph: .symbol("play.fill"),
                    tint: Color(hex: 0x1F5FD1), newWindow: .run(project: projectID, run: id)
                ) { model.showRun(live) }
            }
        }
    }

    private var actionCommands: [PaletteCommand] {
        let action = Color(hex: 0x0A84FF, opacity: 0.5)
        guard let project = model.currentProject else {
            return [PaletteCommand(id: "new-project", title: "New Project…", glyph: .symbol("plus"), tint: action, shortcut: "⌘N") { model.newProject() }]
        }
        let lead: RoleDefinition? = model.leadRole(in: project)
        let config = model.config(for: project)
        var commands = [
            PaletteCommand(id: "new-chat", title: "New chat", meta: lead.map { "with \($0.name)" } ?? "", glyph: .symbol("plus"), tint: action, shortcut: "⌘N") { model.newChat() },
            PaletteCommand(id: "encode", title: "Encode a correction…", meta: "AGENTS.md, check or protected path", glyph: .symbol("arrow.triangle.2.circlepath"), tint: action) {
                model.openSettings(.learnedRules, in: project)
            },
            PaletteCommand(id: "spawn", title: "Spawn agent…", glyph: .symbol("plus"), tint: action, shortcut: "⇧⌘A") { model.spawnAgent() },
            PaletteCommand(id: "pause-all", title: "Pause all agents", meta: project.name, glyph: .symbol("pause.fill"), tint: action, shortcut: "⇧⌘P") {
                model.pauseAllAgents(in: project)
            },
        ]
        if model.hasPendingPins(in: project) {
            commands.insert(PaletteCommand(id: "pins", title: "Approve pins", meta: "Changes", glyph: .symbol("pin.fill"), tint: action) {
                model.setTab(.changes, for: project)
            }, at: 2)
        }
        if let workflow = config.workflow(config.preferences.defaultWorkflow ?? "") ?? config.workflows.first {
            commands.insert(PaletteCommand(id: "test-run", title: "Test run \(workflow.displayName)", meta: "dry run", glyph: .symbol("play"), tint: action) {
                model.testRun(workflow, in: project)
            }, at: min(commands.count, 4))
        }
        return commands
    }

    private var agentCommands: [PaletteCommand] {
        let projects = model.currentProject.map { [$0] } ?? model.openProjects
        return projects.flatMap { project in
            model.agentSessions(in: project)
                .filter { $0.agent.archivedAt == nil }
                .map { session in
                    let role = model.config(for: project).role(session.agent.role)
                    let detail = session.agent.task.isEmpty ? (role?.name ?? session.agent.role) + (session.agent.isPinned ? " · pinned" : "") : session.agent.task
                    return PaletteCommand(
                        id: "agent-\(session.id)", title: model.displayName(of: session.agent, in: project), meta: detail,
                        keywords: role?.name ?? "", glyph: .role(role),
                        newWindow: project.id.map { .agent(project: $0, agent: session.id) }
                    ) { model.openAgent(session, in: project) }
                }
        }
    }

    private var goToCommands: [PaletteCommand] {
        var commands = [
            PaletteCommand(id: "go-inbox", title: "Inbox", meta: model.inboxCount > 0 ? "\(model.inboxCount) waiting" : "", glyph: .symbol("tray")) { model.open(.inbox) },
        ]
        if let project = model.currentProject {
            commands += ProjectTab.sidebarOrder.map { tab in
                PaletteCommand(id: "go-\(tab.rawValue)", title: tab.title, meta: project.name, glyph: .symbol(tab.paletteSymbol)) {
                    if let tool = MainTool(tab: tab) { model.open(tool) } else { model.expand(project) }
                }
            }
            commands += SettingsSection.allCases.map { section in
                PaletteCommand(id: "settings-\(section.rawValue)", title: "Settings › \(section.title)", glyph: .symbol(section.symbol)) {
                    model.openSettings(section, in: project)
                }
            }
        }
        commands += [
            PaletteCommand(id: "go-usage", title: "Usage", meta: String(format: "$%.2f this week · $%.2f this month", model.weeklySpend, model.monthlySpend), glyph: .symbol("chart.bar")) { model.open(.usage) },
            PaletteCommand(id: "go-quality", title: "Quality", glyph: .symbol("gauge.with.dots.needle.33percent")) {
                model.mainWindow.spec = nil
                model.selection = .quality
            },
        ]
        commands += model.openProjects.compactMap { project in
            guard let id = project.id, id != model.currentProject?.id else { return nil }
            return PaletteCommand(id: "project-\(id)", title: project.name, meta: "Switch project", glyph: .symbol("folder")) { model.expand(project) }
        }
        return commands
    }

    private var fileCommands: [PaletteCommand] {
        guard let project = model.currentProject, let projectID = project.id else { return [] }
        let files = model.codeBrowser(for: project).snapshot?.files ?? []
        let needle = searchText
        return files
            .filter { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(needle) }
            .prefix(8)
            .map { path in
                PaletteCommand(
                    id: "file-\(path)", title: (path as NSString).lastPathComponent, meta: path, glyph: .symbol("doc.text"),
                    newWindow: .file(project: projectID, path: path)
                ) { model.openFile(path, in: project) }
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
