import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case roles
    case documentation
    case skills
    case agents
    case claudeAccess
    case tools
    case github

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .roles: "Roles"
        case .documentation: "Documentation"
        case .skills: "Skills"
        case .agents: "Agents & models"
        case .claudeAccess: "Claude access"
        case .tools: "Tools"
        case .github: "GitHub"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .roles: "person.2"
        case .documentation: "doc.text"
        case .skills: "sparkles"
        case .agents: "cpu"
        case .claudeAccess: "key"
        case .tools: "wrench.and.screwdriver"
        case .github: "arrow.triangle.pull"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(hex: 0x636366)
        case .roles: Color(hex: 0xC46A10)
        case .documentation: Color(hex: 0x0A84FF)
        case .skills: Color(hex: 0x8E4FD9)
        case .agents: Color(hex: 0x2E9C5A)
        case .claudeAccess: Color(hex: 0xC23A54)
        case .tools: Color(hex: 0x48484A)
        case .github: Color(hex: 0x48484A)
        }
    }
}

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let branch: String?
    @SceneStorage("projectSettings.section") private var section: SettingsSection = .general

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sidebar
            Group {
                switch section {
                case .general: GeneralSettings(project: project, branch: branch)
                case .roles: RolesSettingsView(project: project)
                case .documentation: DocsSettingsView(project: project)
                case .skills: SkillsSettingsView(project: project)
                case .agents: AgentsSettings(project: project)
                case .claudeAccess: ClaudeAccessSettings()
                case .tools: ToolsSettings()
                case .github: GitHubSettingsView(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                let isSelected = item == section
                Button {
                    section = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(item.tint, in: .rect(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(isSelected ? Theme.accent.opacity(0.28) : Color.clear, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 210)
        .card(cornerRadius: 16)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 20, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct IssueList: View {
    let issues: [ConfigIssue]
    var showsFile = true

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .accessibilityLabel("Problem")
                        Text(showsFile ? "\(issue.file): \(issue.message)" : issue.message)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let branch: String?

    var body: some View {
        let config = model.config(for: project)
        SettingsPage("General", subtitle: "Where this project lives and the state of its Ensemble config.") {
            VStack(alignment: .leading, spacing: 10) {
                row("Folder") {
                    HStack {
                        Text(project.path.abbreviatingHome).font(Theme.monospaced).textSelection(.enabled)
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                            .buttonStyle(.link)
                    }
                }
                row("Branch") { Text(branch ?? "detached").font(Theme.monospaced) }
                row("Worktrees") { Text("\(model.state(for: project).worktrees.count) in \(WorktreeManager.directoryName)/") }
                row("Config") {
                    Text(model.hasConfig(project)
                         ? "\(config.roles.count) roles · \(config.workflows.count) workflows · \(config.docs.docs.count) documents"
                         : "No \(ProjectConfig.directoryName)/ folder yet")
                }
            }
            .padding(16)
            .card(cornerRadius: 16)

            if !model.hasConfig(project) {
                InstallDefaultsCard(project: project)
            }
            IssueList(issues: config.issues)
            Button("Reload Config") { model.reloadConfig(for: project) }
                .buttonStyle(.pill)
                .help("Read .ensemble/ again from disk")
        }
    }

    private func row(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Theme.secondaryText).frame(width: 110, alignment: .leading)
            value()
            Spacer()
        }
        .font(.system(size: 13))
    }
}

private struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let limit = project.settings.maxConcurrentAgents
        let projectID = project.id ?? -1
        SettingsPage("Agents & models", subtitle: "How many agents in this project may run a turn at the same time. Turns beyond the limit wait as Queued and start when a slot frees.") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Max concurrent agents").font(.system(size: 13.5, weight: .semibold))
                    Text("\(model.agents.runningCount(inProject: projectID)) running · \(model.agents.queuedSessions(inProject: projectID).count) queued")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                CountStepper(count: Binding(
                    get: { limit },
                    set: { newValue in
                        var settings = project.settings
                        settings.maxConcurrentAgents = newValue
                        model.updateSettings(settings, for: project)
                    }
                ), range: 1...16)
                .help("Agents allowed to run at once in this project")
            }
            .padding(16)
            .card(cornerRadius: 16)

            Text("Each role picks its model in Settings › Roles.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct ClaudeAccessSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage("Claude access", subtitle: "Applies to every project. A change takes effect on each agent’s next turn.") {
            if let environment = model.environment {
                ProviderChoice(status: environment.provider)
                    .padding(16)
                    .card(cornerRadius: 16)
            }
        }
    }
}

private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage("Tools", subtitle: "The command-line tools Ensemble drives.") {
            if let environment = model.environment {
                VStack(alignment: .leading, spacing: 10) {
                    ToolSummary(name: "git", check: environment.git)
                    ToolSummary(name: "Claude Code", check: environment.claude)
                }
                .padding(16)
                .card(cornerRadius: 16)
            }
        }
    }
}

private struct ToolSummary: View {
    let name: String
    let check: ToolCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).frame(width: 110, alignment: .leading).foregroundStyle(Theme.secondaryText)
            switch check {
            case .found(let path, let version):
                Text("\(version) · \(path.path.abbreviatingHome)").font(Theme.monospaced).textSelection(.enabled)
            case .missing:
                Text("Not found").foregroundStyle(Theme.warning)
            case .broken(_, let message):
                Text(message).foregroundStyle(Theme.warning)
            }
            Spacer()
        }
        .font(.system(size: 13))
    }
}
