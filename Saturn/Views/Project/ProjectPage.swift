import SaturnCore
import SaturnUI
import SwiftUI

struct ProjectPage: View {
    @Environment(DaemonWorkspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    let project: Project
    let section: ProjectSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                ProjectHeader(project: project)
                ProjectSectionNav(project: project, current: section.key, select: select)
            }
            .padding(EdgeInsets(top: 22, leading: 40, bottom: 0, trailing: 40))
            .background(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
            if let recovery = workspace.state(for: project).recovery, !recovery.isClean {
                RecoveryBanner(recovery: recovery) { openWindow(id: WindowID.debugWorktrees) }
                    .padding(EdgeInsets(top: 14, leading: 40, bottom: 0, trailing: 40))
            }
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Tokens.window)
        .onChange(of: project.id.flatMap { workspace.settingsSections[$0] }) { _, settings in
            guard case .settings(let shown) = section, let settings, settings != shown else { return }
            workspace.openProject(project, section: .settings(settings))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(project.name)")
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .overview:
            ScrollView { ProjectOverview(project: project) { select($0) }.padding(EdgeInsets(top: 26, leading: 40, bottom: 40, trailing: 40)) }
        case .chats:
            ScrollView { ProjectChats(project: project).padding(EdgeInsets(top: 26, leading: 40, bottom: 40, trailing: 40)) }
        default:
            ProjectToolSection(project: project, section: section)
        }
    }

    private func select(_ key: ProjectPageSection) {
        let settings = project.id.flatMap { workspace.settingsSections[$0] } ?? .general
        workspace.openProject(project, section: ProjectSection(key, settings: settings))
    }
}

extension DaemonWorkspace {
    func chatSummaries(in project: Project) -> (open: [ChatSummary], closed: [ChatSummary]) {
        let all = chatSummaries()
        let mine = { (summary: ChatSummary) in summary.project.id == project.id }
        return (all.open.filter(mine).sorted { $0.lastActivity > $1.lastActivity }, all.closed.filter(mine))
    }

    func liveAgents(in project: Project) -> [LiveAgentSession] {
        agentSessions(in: project).filter { $0.agent.archivedAt == nil }
    }

    func pendingReviewCount(in project: Project) -> Int {
        guard let id = project.id else { return 0 }
        let held = reviewableRuns(in: project).count { holdsForApproval($0) }
        let pins = requests.items.count { $0.projectId == id && $0.kind == .pinReview && $0.status == .open }
        return held + pins
    }

    func pendingAsk(for chat: Chat) -> ChatRequest? {
        requests.items.first { $0.taskId == chat.id && $0.status == .open && Self.needsYouKinds.contains($0.kind) }
    }

    func hasOpenProposal(_ chat: Chat) -> Bool {
        guard let id = chat.id else { return false }
        return ((try? database.openProposalChatIDs(projectId: chat.projectId)) ?? []).contains(id)
    }

    func subtitle(of summary: ChatSummary) -> String {
        if let request = pendingAsk(for: summary.chat) { return request.title }
        if let detail = summary.detail { return detail }
        if summary.stage.needsAttention, hasOpenProposal(summary.chat) { return "The spec is ready for your approval" }
        if let run = latestRun(of: summary.chat) {
            if run.isActive, let step = run.currentStep.flatMap({ runWorkflow(run)?.step($0) }) { return step.displayTitle }
            if run.mergedAt != nil { return "Merged into \(run.baseBranch ?? "the base branch")" }
            if let error = run.lastError, summary.stage == .stuck { return error }
        }
        return summary.stage == .idle ? "Not started yet" : summary.stage.title
    }

    func branch(of summary: ChatSummary) -> String? {
        latestRun(of: summary.chat)?.deliveryBranch ?? summary.workers.lazy.compactMap(\.branch).first
    }
}

struct ProjectSectionHeading<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.semibold).foregroundStyle(Tokens.text2)
            if let detail { Text(detail).foregroundStyle(Tokens.text3) }
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 12.5))
        .accessibilityAddTraits(.isHeader)
    }
}

extension ProjectSectionHeading where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct ProjectLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Tokens.link)
    }
}

struct SmallPillStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Tokens.primaryForeground : Tokens.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(isPrimary ? Tokens.primaryBackground.opacity(configuration.isPressed ? 0.8 : 1) : configuration.isPressed ? Tokens.hover : .clear, in: Capsule())
            .overlay { if !isPrimary { Capsule().strokeBorder(Tokens.hair2) } }
            .contentShape(Capsule())
    }
}

extension View {
    func projectCard(radius: CGFloat = 14) -> some View {
        background(Tokens.raised, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Tokens.hair))
    }
}
