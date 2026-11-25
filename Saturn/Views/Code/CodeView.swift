import SaturnCore
import SaturnUI
import SwiftUI

struct CodeView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    var body: some View {
        let browser = workspace.codeBrowser(for: project)
        HStack(spacing: 0) {
            CodeExplorer(browser: browser)
                .frame(width: 260)
            Rectangle().fill(Tokens.hair).frame(width: 1)
            CodeReader(browser: browser, project: project)
        }
        .background(Tokens.raised)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.hair))
        .overlay {
            if browser.isFinderPresented {
                CodeFinder(browser: browser)
            }
        }
        .background {
            Button("Go to File") { browser.presentFinder() }
                .keyboardShortcut("p", modifiers: .command)
                .hidden()
        }
        .task(id: project.id) { await browser.refreshSources() }
        .onChange(of: workspace.agentSessions(in: project).map(\.id)) {
            Task { await browser.refreshSources() }
        }
    }
}

struct CodeExplorer: View {
    @Bindable var browser: CodeBrowser

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button { browser.presentFinder() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                        Text("Go to file").frame(maxWidth: .infinity, alignment: .leading)
                        Text("⌘P").font(Tokens.mono(11)).foregroundStyle(Tokens.text3)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Tokens.fill, in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair2))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Go to file")
                SourcePicker(browser: browser)
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.text3)
                        .accessibilityHidden(true)
                    TextField("Filter files", text: $browser.filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Tokens.window.opacity(0.4), in: .rect(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair))
            }
            .padding(10)

            FileTree(browser: browser)

            HStack(spacing: 6) {
                ChangeDot(color: Tokens.review)
                Text(browser.source?.agent == nil ? "uncommitted" : "changed by this agent")
                ChangeDot(color: Tokens.done).padding(.leading, 6)
                Text("added")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
        }
        .background(Tokens.side)
    }
}

struct ChangeDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

private struct SourcePicker: View {
    let browser: CodeBrowser

    var body: some View {
        Menu {
            ForEach(browser.sources) { source in
                Button {
                    Task { await browser.select(source) }
                } label: {
                    Text(source.title)
                    if let branch = source.branch { Text(branch) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                SourceSwatch(source: browser.source)
                VStack(alignment: .leading, spacing: 0) {
                    Text(browser.source?.title ?? "Project checkout")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(browser.source?.branch ?? "")
                        .font(Tokens.mono(10.5))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.text3)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(Tokens.fill, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Worktree: \(browser.source?.branch ?? browser.source?.title ?? ""). Change worktree")
    }
}

private struct SourceSwatch: View {
    let source: CodeSource?

    var body: some View {
        Group {
            if let agent = source?.agent {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(RoleAppearance(role: source?.role).palette.gradient)
                    .overlay {
                        Image(systemName: RoleAppearance(role: source?.role).symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .help(AgentNaming.displayName(of: agent))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Tokens.fill2)
                    .overlay { Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Tokens.link) }
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct FileTree: View {
    let browser: CodeBrowser

    var body: some View {
        Group {
            if let error = browser.loadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.danger)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if browser.snapshot == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = browser.rows
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            FileTreeRow(browser: browser, row: row)
                        }
                        if rows.isEmpty {
                            Text(browser.filter.isEmpty ? "No files" : "No files match “\(browser.filter)”")
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text3)
                                .padding(12)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 10, trailing: 6))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct FileTreeRow: View {
    @Environment(\.isInWorkbench) private var isInWorkbench
    let browser: CodeBrowser
    let row: CodeTreeRow

    var body: some View {
        let isActive = !row.isDirectory && browser.activePath == row.path
        let change = row.isDirectory ? nil : browser.change(for: row.path)
        let isOpen = browser.expanded.contains(row.path)
        Button {
            if row.isDirectory { browser.toggle(row.path) } else { browser.open(row.path) }
        } label: {
            HStack(spacing: 6) {
                Text(row.isDirectory ? (isOpen ? "▾" : "▸") : "")
                    .foregroundStyle(Tokens.text3)
                    .frame(width: 10, alignment: .leading)
                Text(row.name)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !row.isDirectory, browser.pins[row.path]?.isEmpty == false {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.review)
                        .accessibilityLabel("Has a pin")
                }
                if let change {
                    ChangeDot(color: CodeStyle.changeColor(change.status))
                        .help(change.status == .added ? "Added" : "Changed")
                        .accessibilityLabel(change.status == .added ? "Added" : "Changed")
                } else if row.isDirectory, !isOpen, browser.directoryHasChanges(row.path) {
                    ChangeDot(color: Tokens.review)
                        .help("Contains changes")
                }
            }
            .font(Tokens.mono(12))
            .padding(.leading, 8 + CGFloat(row.depth) * 14)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(isActive ? Tokens.selection : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isInWorkbench, !row.isDirectory, let id = browser.project.id {
                ContextCommands(groups: ContextCommands.file, target: .file(project: id, path: row.path))
            }
        }
        .accessibilityLabel(row.isDirectory ? "\(row.name) folder, \(isOpen ? "expanded" : "collapsed")" : row.path)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
