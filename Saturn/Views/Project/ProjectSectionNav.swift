import SaturnCore
import SaturnUI
import SwiftUI

struct ProjectSectionNav: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let current: ProjectPageSection
    let select: (ProjectPageSection) -> Void

    var body: some View {
        let counts = sectionCounts
        HStack(spacing: 4) {
            ForEach(ProjectPageSection.navOrder, id: \.self) { section in
                item(section, count: counts[section])
            }
        }
        .padding(.bottom, -1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project sections")
    }

    private var sectionCounts: [ProjectPageSection: SectionCount] {
        var counts: [ProjectPageSection: SectionCount] = [:]
        let chats = workspace.chatSummaries(in: project).open.count
        if chats > 0 { counts[.chats] = SectionCount(value: chats) }
        let agents = workspace.liveAgents(in: project).count
        if agents > 0 { counts[.agents] = SectionCount(value: agents) }
        let reviews = workspace.pendingReviewCount(in: project)
        if reviews > 0 { counts[.changes] = SectionCount(value: reviews, needsYou: true) }
        return counts
    }

    private func item(_ section: ProjectPageSection, count: SectionCount?) -> some View {
        let isCurrent = section == current
        return Button { select(section) } label: {
            HStack(spacing: 7) {
                Image(systemName: section.systemImage).font(.system(size: 12))
                Text(section.title)
                if let count {
                    Text("\(count.value)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(count.needsYou ? Tokens.primaryForeground : Tokens.text2)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(count.needsYou ? Tokens.review : Tokens.fill2, in: Capsule())
                }
            }
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Tokens.text : Tokens.text2)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle().fill(isCurrent ? Tokens.accent : .clear).frame(height: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(section.title), \($0.value)\($0.needsYou ? " need you" : "")" } ?? section.title)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }
}

private struct SectionCount {
    let value: Int
    var needsYou = false
}
