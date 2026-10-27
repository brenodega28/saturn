import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct SourceNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        if let project = model.currentProject, let id = project.id {
            let browser = model.codeBrowser(for: project)
            CodeExplorer(browser: browser)
                .task(id: id) { await browser.refreshSources() }
                .onChange(of: browser.activePath) { _, path in
                    if let path { state.open(.file(path, in: id)) }
                }
        } else {
            NavigatorEmpty(title: "No project", message: "Open a project to browse its files.")
        }
    }
}

struct GitBranchInfo: Identifiable, Hashable {
    let name: String
    let tracking: String
    let date: String

    var id: String { name }
}

struct GitCommitInfo: Identifiable, Hashable {
    let hash: String
    let subject: String
    let author: String
    let date: String

    var id: String { hash }
}

struct SourceControlNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @State private var branches: [GitBranchInfo] = []
    @State private var commits: [GitCommitInfo] = []
    @State private var error: String?

    var body: some View {
        if let project = model.currentProject, let id = project.id {
            let worktrees = model.state(for: project).worktrees.filter { $0.path.standardizedFileURL != project.url.standardizedFileURL }
            let sessions = model.agentSessions(in: project)
            let pullRequests = model.runs(in: [project]).filter { $0.pullRequestURL != nil }.reversed()
            NavigatorList {
                if let error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger).padding(8)
                }
                NavigatorSection(title: "Branches", count: branches.count) {
                    ForEach(branches) { branch in
                        let session = sessions.first { $0.agent.branch == branch.name }
                        NavigatorRow(title: branch.name, detail: [branch.tracking, branch.date].filter { !$0.isEmpty }.joined(separator: " · "), monospacedTitle: true) {
                            if let session { state.open(.agent(session.id, in: id)) }
                        } leading: {
                            BranchSwatch(role: session.flatMap { model.role(for: $0.agent, in: project) })
                        }
                    }
                }
                if !worktrees.isEmpty {
                    NavigatorSection(title: "Worktrees", count: worktrees.count) {
                        ForEach(worktrees) { worktree in
                            let session = sessions.first { $0.agent.worktreeURL?.standardizedFileURL == worktree.path.standardizedFileURL }
                            NavigatorRow(title: ".crew/\(worktree.agent)", detail: worktree.branch ?? "detached", monospacedTitle: true) {
                                if let session { state.open(.agent(session.id, in: id)) }
                            } leading: {
                                BranchSwatch(role: session.flatMap { model.role(for: $0.agent, in: project) })
                            }
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.path]) }
                                Button("Open in Terminal") { model.openInTerminal(worktree.path) }
                            }
                        }
                    }
                }
                NavigatorSection(title: "Recent commits", count: commits.count) {
                    ForEach(commits) { commit in
                        NavigatorRow(title: commit.subject, detail: "\(commit.author) · \(commit.date) · \(commit.hash)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                        } leading: {
                            BranchSwatch(role: nil)
                        }
                        .help("Copy \(commit.hash)")
                    }
                }
                if !pullRequests.isEmpty {
                    NavigatorSection(title: "Pull requests", count: pullRequests.count) {
                        ForEach(Array(pullRequests)) { run in
                            NavigatorRow(title: run.displayTitle, detail: run.mergedAt == nil ? "open" : "merged") {
                                if let url = run.pullRequestURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
                            } leading: {
                                Image(systemName: "arrow.triangle.pull").font(.system(size: 11)).frame(width: 16).padding(.top, 2)
                            }
                        }
                    }
                }
            }
            .task(id: "\(id)-\(sessions.count)-\(model.engine.runs.count)") { await load(project) }
        } else {
            NavigatorEmpty(title: "No project", message: "Open a project to see its branches and commits.")
        }
    }

    private func load(_ project: Project) async {
        guard let git = model.git else { return }
        do {
            let refs = try await git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)\t%(upstream:track)\t%(committerdate:relative)", "refs/heads"], in: project.url)
            branches = refs.split(separator: "\n").map { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return GitBranchInfo(name: parts[0], tracking: parts.count > 1 ? parts[1] : "", date: parts.count > 2 ? parts[2] : "")
            }
            let log = try await git.run(["log", "--branches", "-n", "15", "--format=%h\t%s\t%an\t%cr"], in: project.url)
            commits = log.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { return nil }
                return GitCommitInfo(hash: parts[0], subject: parts[1], author: parts[2], date: parts[3])
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BranchSwatch: View {
    let role: RoleDefinition?

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(role.map { RoleAppearance(role: $0).palette.gradient } ?? LinearGradient(colors: [Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom))
            .frame(width: 14, height: 14)
            .padding(.top, 2)
            .accessibilityHidden(true)
    }
}

struct FindHit: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case code = "Code"
        case transcripts = "Transcripts"
        case pins = "Pins"
    }

    let group: Group
    let title: String
    let text: String
    var file: String?
    var line: Int?
    var agent: Int64?
    var run: Int64?
    let project: Int64

    var id: String { [group.rawValue, title, text, "\(project)"].joined(separator: "|") }
}

struct FindNavigator: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @State private var query = ""
    @State private var hits: [FindHit] = []
    @State private var isSearching = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                TextField("Find in code, transcripts and pins", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isFocused)
                    .onSubmit { Task { await search() } }
                if isSearching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isFocused ? Theme.accent : Color.white.opacity(0.06)))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if hits.isEmpty {
                NavigatorEmpty(title: query.isEmpty ? "Search everything" : "No matches", message: query.isEmpty ? "Press ↵ to search code, agent transcripts and pins." : "Nothing matches “\(query)”.")
            } else {
                NavigatorList {
                    ForEach(FindHit.Group.allCases, id: \.self) { group in
                        let matching = hits.filter { $0.group == group }
                        if !matching.isEmpty {
                            NavigatorSection(title: group.rawValue, count: matching.count) {
                                ForEach(matching) { hit in
                                    FindHitRow(hit: hit, query: query)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { isFocused = true }
    }

    private func search() async {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { hits = []; return }
        isSearching = true
        defer { isSearching = false }
        var found: [FindHit] = []
        for project in model.navigatorProjects(state.navigatorScope) {
            guard let id = project.id else { continue }
            if let git = model.git, let output = try? await git.run(["grep", "-n", "-I", "-i", "-F", "--max-count=3", "-e", needle], in: project.url) {
                for line in output.split(separator: "\n").prefix(40) {
                    let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 3 else { continue }
                    found.append(FindHit(group: .code, title: "\(parts[0]):\(parts[1])", text: parts[2].trimmingCharacters(in: .whitespaces), file: parts[0], line: Int(parts[1]), project: id))
                }
            }
            for session in model.agentSessions(in: project) {
                for entry in session.transcript.entries {
                    guard let text = entry.searchableText, text.localizedCaseInsensitiveContains(needle) else { continue }
                    found.append(FindHit(group: .transcripts, title: model.displayName(of: session.agent, in: project), text: excerpt(text, around: needle), agent: session.id, project: id))
                    if found.filter({ $0.group == .transcripts }).count >= 30 { break }
                }
            }
            for run in model.runs(in: [project]) {
                guard let runID = run.id else { continue }
                for pin in (try? model.database.pins(runId: runID)) ?? [] where (pin.title + " " + pin.explanation).localizedCaseInsensitiveContains(needle) {
                    found.append(FindHit(group: .pins, title: "\((pin.file as NSString).lastPathComponent):\(pin.startLine)", text: pin.title, file: pin.file, line: pin.startLine, run: runID, project: id))
                }
            }
        }
        hits = found
    }

    private func excerpt(_ text: String, around needle: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: needle, options: .caseInsensitive) else { return String(flat.prefix(140)) }
        let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start == flat.startIndex ? "" : "…") + flat[start..<end] + (end == flat.endIndex ? "" : "…")
    }
}

private struct FindHitRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let hit: FindHit
    let query: String

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Text(highlighted).font(.system(size: 12)).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var highlighted: AttributedString {
        var string = AttributedString(hit.text)
        var searchStart = string.startIndex
        while searchStart < string.endIndex, let range = string[searchStart...].range(of: query, options: .caseInsensitive) {
            string[range].backgroundColor = Theme.warning.opacity(0.35)
            searchStart = range.upperBound
        }
        return string
    }

    private func open() {
        switch hit.group {
        case .code:
            guard let file = hit.file, let project = model.project(withID: hit.project) else { return }
            model.codeBrowser(for: project).open(file, line: hit.line)
            state.open(.file(file, in: hit.project))
        case .transcripts:
            if let agent = hit.agent { state.open(.agent(agent, in: hit.project)) }
        case .pins:
            if let run = hit.run {
                model.changesRunSelections[hit.project] = run
                state.open(.section(.changes, in: hit.project))
            }
        }
    }
}

extension TranscriptEntry {
    var searchableText: String? {
        switch content {
        case .user(let text), .assistant(let text): text
        default: nil
        }
    }
}

extension AppModel {
    func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
