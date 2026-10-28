import EnsembleCore
import EnsembleUI
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                launcher
                recents
            }
            .padding(8)
            .background(Theme.windowBackground, in: .rect(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
            .frame(maxWidth: 940)
            .padding(.horizontal, 24)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop())
    }

    private var launcher: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                AppMark(size: 96)
                VStack(spacing: 4) {
                    Text("Ensemble").font(.system(size: 26, weight: .bold)).kerning(-0.5)
                    Text("Agents propose. Rails verify. You approve.").foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.top, 30)

            VStack(spacing: 8) {
                LauncherButton(title: "Open Folder…", systemImage: "folder", shortcut: "⌘O", isPrimary: true) {
                    model.isOpenPanelPresented = true
                }
                LauncherButton(title: "Clone Repository…", systemImage: "arrow.triangle.branch", shortcut: "⇧⌘O", isPrimary: false) {
                    model.isClonePresented = true
                }
                LauncherButton(title: "New Project", systemImage: "plus.rectangle.on.folder", shortcut: "⌘N", isPrimary: false) {
                    model.newProject()
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 22, trailing: 18))
        .frame(width: 320)
        .frame(minHeight: 420, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Recent projects").padding(.bottom, 4)
                if model.recentProjects.isEmpty {
                    Text("Projects you open show up here.")
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.vertical, 10)
                } else {
                    ForEach(model.recentProjects) { project in
                        RecentProjectRow(project: project)
                    }
                }
            }
            CrewTemplatesSection()
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 22))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LauncherButton: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(isPrimary ? Color.white.opacity(0.8) : Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(isPrimary ? .primary : .secondary, height: 40))
    }
}

private struct RecentProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var isHovered = false

    var body: some View {
        Button {
            Task { await model.openFolder(project.url) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.link)
                    .frame(width: 36, height: 36)
                    .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 14, weight: .semibold))
                    Text(project.path.abbreviatingHome)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let activity = model.recentActivity(of: project) {
                    Text(activity.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(activity.isFailure ? Theme.danger : Theme.successText)
                }
                Text(project.lastOpenedAt.relativeDay)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.white.opacity(0.06) : .clear, in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button("Remove from Recents") { model.forgetRecent(project) }
        }
    }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}

extension Date {
    var relativeDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
