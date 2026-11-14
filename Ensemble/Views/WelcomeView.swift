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
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Tokens.hair2))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
            .frame(maxWidth: 940)
            .padding(.horizontal, 24)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop())
    }

    @AppStorage(Appearance.storageKey, store: AppDefaults.store) private var appearance = Appearance.fallback

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                AppMark(size: 56)
                Text("Ensemble").font(.system(size: 34, weight: .heavy).width(.expanded)).foregroundStyle(Tokens.text)
                Text("Agentic development, done right. Agents propose, checks verify, you approve.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WelcomeStep(number: 1, title: "Claude CLI", isDone: model.environment?.claude.isOK == true) {
                Text(claudeLine).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).fixedSize(horizontal: false, vertical: true)
            }
            WelcomeStep(number: 2, title: "Appearance", isDone: true) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            WelcomeStep(number: 3, title: "Add your first project", isDone: false) {
                VStack(spacing: 8) {
                    LauncherButton(title: "Folder on this Mac…", systemImage: "folder", shortcut: "⌘O", isPrimary: true) {
                        model.isOpenPanelPresented = true
                    }
                    LauncherButton(title: "SSH host…", systemImage: "network", shortcut: "", isPrimary: false) {
                        model.isRemoteFolderPresented = true
                    }
                    LauncherButton(title: "Clone a repository…", systemImage: "arrow.triangle.branch", shortcut: "⇧⌘O", isPrimary: false) {
                        model.isClonePresented = true
                    }
                    LauncherButton(title: "New project", systemImage: "plus.rectangle.on.folder", shortcut: "⌘N", isPrimary: false) {
                        model.newProject()
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22))
        .frame(width: 340)
        .frame(minHeight: 420, alignment: .top)
        .background(Tokens.raised, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var claudeLine: String {
        switch model.environment?.claude {
        case .found(let path, let version): "Found claude \(version) at \((path.path as NSString).abbreviatingWithTildeInPath)"
        case .broken(_, let message): message
        case .missing, nil: "Not found yet. Install Claude Code, then reopen Ensemble."
        }
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
            Task { await model.reopen(project) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: project.isRemote ? "network" : "folder")
                    .foregroundStyle(Theme.link)
                    .frame(width: 36, height: 36)
                    .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 14, weight: .semibold))
                    Text(project.isRemote ? project.location : project.path.abbreviatingHome)
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
            .background(isHovered ? Tokens.fill : .clear, in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if !project.isRemote {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            }
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

private struct WelcomeStep<Content: View>: View {
    let number: Int
    let title: String
    let isDone: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(isDone ? Tokens.doneBackground : Tokens.fill)
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.done)
                } else {
                    Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(Tokens.text2)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text)
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title)")
    }
}
