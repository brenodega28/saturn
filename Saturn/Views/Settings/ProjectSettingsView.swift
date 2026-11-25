import AppKit
import SaturnCore
import SaturnUI
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case documentation
    case skills
    case agents
    case workspaces
    case checks
    case permissions
    case learnedRules
    case claudeAccess
    case tools

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .documentation: "Docs"
        case .skills: "Skills"
        case .agents: "Roles"
        case .workspaces: "Workspaces"
        case .checks: "Checks"
        case .permissions: "Permissions"
        case .learnedRules: "Learned rules"
        case .claudeAccess: "Claude access"
        case .tools: "Tools"
        }
    }

    var shortTitle: String {
        switch self {
        case .general: "General"
        case .documentation: "Docs"
        case .skills: "Skills"
        case .agents: "Roles"
        case .workspaces: "Spaces"
        case .checks: "Checks"
        case .permissions: "Perms"
        case .learnedRules: "Rules"
        case .claudeAccess: "Access"
        case .tools: "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .documentation: "doc.text"
        case .skills: "bolt"
        case .agents: "person"
        case .workspaces: "arrow.triangle.branch"
        case .checks: "checkmark.square"
        case .permissions: "shield"
        case .learnedRules: "brain"
        case .claudeAccess: "key"
        case .tools: "wrench.and.screwdriver"
        }
    }

    static let displayOrder: [SettingsSection] = [.agents, .checks, .permissions, .documentation, .skills, .workspaces, .general, .learnedRules, .claudeAccess, .tools]
}

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let branch: String?

    var body: some View {
        SettingsContainer(project: project, branch: branch, section: Binding(
            get: { project.id.flatMap { workspace.settingsSections[$0] } ?? .general },
            set: { section in project.id.map { workspace.settingsSections[$0] = section } }
        ))
    }
}

struct SettingsContainer: View {
    static let fullSidebarMinimumWidth: CGFloat = 760

    let project: Project
    let branch: String?
    @Binding var section: SettingsSection
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        let isCompact = availableWidth > 0 && availableWidth < Self.fullSidebarMinimumWidth
        HStack(alignment: .top, spacing: isCompact ? 16 : 28) {
            tabList(isCompact: isCompact)
            Group {
                switch section {
                case .general: GeneralSettings(project: project, branch: branch)
                case .documentation: DocsSettingsView(project: project)
                case .skills: SkillsSettingsView(project: project)
                case .agents: AgentsSettings(project: project)
                case .workspaces: WorkspacesSettingsView(project: project)
                case .checks: ChecksSettingsView(project: project)
                case .permissions: PermissionsSettingsView(project: project)
                case .learnedRules: LearnedRulesView(project: project)
                case .claudeAccess: ClaudeAccessSettings()
                case .tools: ToolsSettings()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func tabList(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.displayOrder) { item in
                SettingsTab(section: item, isSelected: item == section, isCompact: isCompact) { section = item }
            }
            if !isCompact {
                Text("Applies to \(project.name) only. App-wide settings are under ⌘,.")
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
            }
        }
        .frame(width: isCompact ? 38 : 200, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project settings")
    }
}

private struct SettingsTab: View {
    let section: SettingsSection
    let isSelected: Bool
    let isCompact: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                if !isCompact {
                    Text(section.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(isSelected ? Tokens.accent : Tokens.text)
            .padding(.horizontal, isCompact ? 11 : 10)
            .frame(height: 34)
            .frame(maxWidth: isCompact ? nil : .infinity, alignment: .leading)
            .background(isSelected ? Tokens.selection : .clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .kerning(-0.33)
                        .foregroundStyle(Tokens.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.trailing, 6)
            .padding(.bottom, 20)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

struct SettingsRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview.sectionRow(isFirst: index == 0)
                }
            }
        }
        .sectionCard()
    }
}

struct SettingsRowLabel: View {
    let title: String
    var detail: String = ""
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(monospaced ? Tokens.mono(13.5, weight: .semibold) : .system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.text)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsNote: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = Tokens.text2) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsWarning: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Tokens.need)
            .fixedSize(horizontal: false, vertical: true)
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
                            .foregroundStyle(Tokens.need)
                            .accessibilityLabel("Problem")
                        Text(showsFile ? "\(issue.file): \(issue.message)" : issue.message)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.needBackground, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.needLine))
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let branch: String?

    var body: some View {
        let config = workspace.config(for: project)
        SettingsPage("General", subtitle: "Where \(project.name) lives and the state of its Saturn config.") {
            if project.isRemote {
                RemoteHostCard(project: project)
            }
            SettingsRows {
                HStack(spacing: 14) {
                    SettingsRowLabel(title: "Folder", detail: project.isRemote ? project.location : "On this Mac")
                    Text(project.isRemote ? project.path : project.path.abbreviatingHome)
                        .font(Tokens.mono(12))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if !project.isRemote {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                            .buttonStyle(SectionButtonStyle(height: 28))
                    }
                }
                valueRow("Branch", branch ?? "detached", monospaced: true)
                valueRow("Worktrees", "\(workspace.state(for: project).worktrees.count) in \(WorktreeManager.directoryName)/")
                valueRow("Config", workspace.hasConfig(project)
                    ? "\(config.workflows.count) workflows · \(config.docs.docs.count) documents"
                    : "No \(ProjectConfig.directoryName)/ folder yet")
            }

            if !workspace.hasConfig(project) {
                InstallDefaultsCard(project: project)
            }
            IssueList(issues: config.issues)
            Button("Reload Config") { workspace.reloadConfig(for: project) }
                .buttonStyle(SectionButtonStyle())
                .help("Read .saturn/ again from disk")
        }
    }

    private func valueRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 14) {
            SettingsRowLabel(title: title)
            Text(value)
                .font(monospaced ? Tokens.mono(12) : .system(size: 12.5))
                .foregroundStyle(Tokens.text2)
                .textSelection(.enabled)
        }
    }
}

private struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        let config = workspace.config(for: project)
        let projectID = project.id ?? -1
        SettingsPage("Roles", subtitle: "The kinds of agent the Lead can start in this project, and the limits on each.") {
            SettingsRows {
                ForEach(config.roles) { role in
                    RoleRow(role: role)
                }
            }
            SettingsRows {
                HStack(spacing: 14) {
                    SettingsRowLabel(
                        title: "Max concurrent agents",
                        detail: "\(workspace.connection.runningCount(inProject: projectID)) running · \(workspace.connection.queuedSessions(inProject: projectID).count) queued. Turns beyond the limit wait as Queued."
                    )
                    CountStepper(count: Binding(
                        get: { project.settings.maxConcurrentAgents },
                        set: { value in update { $0.maxConcurrentAgents = value } }
                    ), range: 1...16)
                    .help("Agents allowed to run at once in this project")
                }
                HStack(spacing: 14) {
                    SettingsRowLabel(
                        title: "Review capacity",
                        detail: project.settings.reviewCapacity == 0
                            ? "No limit: runs start building no matter how much waits on you."
                            : "New runs wait before building while \(project.settings.reviewCapacity) or more changes wait for your approval."
                    )
                    CountStepper(count: Binding(
                        get: { project.settings.reviewCapacity },
                        set: { value in update { $0.reviewCapacity = value } }
                    ), range: 0...20)
                    .help("Changes that may wait for your approval before new runs hold off building; 0 means no limit")
                }
            }
            SettingsNote("Each workflow step picks its model; agents you spawn pick theirs in New Agent.")
        }
    }

    private func update(_ change: (inout ProjectSettings) -> Void) {
        var settings = project.settings
        change(&settings)
        workspace.updateSettings(settings, for: project)
    }
}

private struct RoleRow: View {
    let role: RoleDefinition

    var body: some View {
        HStack(spacing: 14) {
            AgentAvatar(size: 34, appearance: RoleAppearance(role: role)).shadow(radius: 0)
            SettingsRowLabel(title: role.name, detail: role.description)
            Text(AgentModel(rawValue: role.model)?.title ?? role.model)
                .font(Tokens.mono(12))
                .foregroundStyle(Tokens.text)
                .frame(width: 100, alignment: .leading)
            Text(role.editsCode ? "Own worktree" : "Reads others’")
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text2)
                .frame(width: 110, alignment: .leading)
        }
    }
}

struct ClaudeAccessSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage("Claude access", subtitle: "Applies to every project. A change takes effect on each agent’s next turn.") {
            if let environment = model.environment {
                ProviderChoice(status: environment.provider)
                    .padding(16)
                    .sectionCard()
            }
        }
    }
}

struct ToolsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage("Tools", subtitle: "The command-line tools Saturn drives.") {
            if let environment = model.environment {
                SettingsRows {
                    ToolSummary(name: "git", check: environment.git)
                    ToolSummary(name: "Claude Code", check: environment.claude)
                }
            }
        }
    }
}

private struct ToolSummary: View {
    let name: String
    let check: ToolCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 14, weight: .semibold)).frame(width: 110, alignment: .leading)
            switch check {
            case .found(let path, let version):
                Text("\(version) · \(path.path.abbreviatingHome)").font(Tokens.mono(12)).foregroundStyle(Tokens.text2).textSelection(.enabled)
            case .missing:
                Text("Not found").foregroundStyle(Tokens.need)
            case .broken(_, let message):
                Text(message).foregroundStyle(Tokens.need)
            }
            Spacer()
        }
        .font(.system(size: 13))
    }
}
