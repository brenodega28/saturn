import EnsembleCore
import EnsembleUI
import SwiftUI

struct CodeView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let browser = model.codeBrowser(for: project)
        HStack(spacing: 0) {
            CodeExplorer(browser: browser)
                .frame(width: 264)
            Divider().overlay(Color.white.opacity(0.06))
            CodeReader(browser: browser, project: project)
        }
        .background(CodeStyle.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
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
        .onChange(of: model.agentSessions(in: project).map(\.id)) {
            Task { await browser.refreshSources() }
        }
    }
}

struct CodeExplorer: View {
    @Bindable var browser: CodeBrowser

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SourcePicker(browser: browser)
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .accessibilityHidden(true)
                        TextField("Filter files", text: $browser.filter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
                    Button { browser.presentFinder() } label: {
                        Text("⌘P")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(height: 30)
                            .padding(.horizontal, 9)
                            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Go to file")
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))

            FileTree(browser: browser)

            HStack(spacing: 6) {
                Text("M").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.successText)
                Text(browser.source?.agent == nil ? "uncommitted" : "changed by this agent")
                Text("A").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(CodeStyle.added).padding(.leading, 6)
                Text("added")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.06)) }
        }
        .background(Color.white.opacity(0.025))
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
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
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
                    .fill(Color.white.opacity(0.1))
                    .overlay { Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.link) }
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
                    .foregroundStyle(Theme.danger)
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
                                .foregroundStyle(Theme.tertiaryText)
                                .padding(12)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 12, trailing: 6))
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
                if row.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 9)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.link.opacity(0.85))
                } else {
                    Spacer().frame(width: 9)
                    FileBadge(path: row.path)
                }
                Text(row.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(change != nil || isActive ? .white : Theme.primaryText.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !row.isDirectory, browser.pins[row.path]?.isEmpty == false {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(CodeStyle.pin)
                        .accessibilityLabel("Has a pin")
                }
                if let change {
                    Text(change.status.mark)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CodeStyle.changeColor(change.status))
                        .help(change.status == .added ? "Added" : "Changed")
                } else if row.isDirectory, !isOpen, browser.directoryHasChanges(row.path) {
                    Text("•")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.successText)
                        .help("Contains changes")
                }
            }
            .padding(.leading, 8 + CGFloat(row.depth) * 14)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(isActive ? Theme.accent.opacity(0.28) : .clear, in: .rect(cornerRadius: 7, style: .continuous))
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
