import AppKit
import SaturnCore
import SaturnUI
import SwiftUI

struct ProjectHeader: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        HStack(spacing: 16) {
            ProjectTile(project: project, size: 52)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                facts
            }
            Spacer(minLength: 12)
            actions
        }
    }

    private var facts: some View {
        HStack(spacing: 12) {
            Label(workspace.isRemote ? workspace.displayName : "This Mac", systemImage: workspace.isRemote ? "server.rack" : "laptopcomputer")
                .labelStyle(TightLabelStyle())
            Text(workspace.isRemote ? project.path : project.path.abbreviatingHome)
                .font(Tokens.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let branch = workspace.state(for: project).branch {
                Label { Text(branch).font(Tokens.mono(12)) } icon: { Image(systemName: "arrow.triangle.branch") }
                    .labelStyle(TightLabelStyle())
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Tokens.text2)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !project.isRemote {
                iconButton("Open in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            }
            iconButton("Open a terminal here", symbol: "terminal") { workspace.openTerminal(in: project) }
            ProjectMoreMenu(project: project)
            Button { workspace.startNewChat(in: project) } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(SmallPillStyle(isPrimary: true))
            .frame(height: 32)
            .help("New chat in \(project.name)")
        }
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Tokens.hair2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ProjectMoreMenu: View {
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        Menu {
            Button("New chat in \(project.name)") { workspace.startNewChat(in: project) }
            if project.isRemote {
                Button("Copy SSH path") { workspace.copyToPasteboard("\(project.location):\(project.path)") }
            } else {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                Button("Copy path") { workspace.copyToPasteboard(project.path) }
            }
            Divider()
            Button("Settings") { workspace.openSettings(.general, in: project) }
            Divider()
            Button("Remove \(project.name) from Saturn…", role: .destructive) { workspace.close(project) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Tokens.hair2))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More for \(project.name)")
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}
