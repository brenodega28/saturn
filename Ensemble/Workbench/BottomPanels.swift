import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

extension WorkbenchRegistry {
    func registerBottomPanels() {
        register(BottomPanelTabSpec(id: "log", title: "Log", order: 0) { AnyView(LogPanel()) })
        register(BottomPanelTabSpec(id: "terminal", title: "Terminal", order: 10) { AnyView(TerminalPanel()) })
        register(BottomPanelTabSpec(id: "checks", title: "Checks", order: 20, badge: { model in
            let runs = model.runs(in: model.navigatorProjects(.project)).filter { ProjectSignals.activeStatuses.contains($0.status) }
            return ProjectSignals.checkBoard(runs: runs, steps: model.steps(of: runs), holds: model.engine.holds).filter { $0.state == .failed || $0.state == .exhausted }.count
        }) { AnyView(ChecksOutputPanel()) })
        register(BottomPanelTabSpec(id: "problems", title: "Problems", order: 30, badge: { model in
            model.problems(scope: .project).count
        }) { AnyView(ProblemsPanel()) })
        register(BottomPanelTabSpec(id: "servers", title: "Servers", order: 40) { AnyView(ServersPanel()) })
        register(BottomPanelTabSpec(id: "activity", title: "Activity", order: 50) { AnyView(ActivityPanel()) })
    }
}

private struct PanelToolbar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(hex: 0x161619))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }
}

struct LogPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @State private var filter = LogFilter()
    @State private var follows = true

    var body: some View {
        let projectIDs = Set(model.navigatorProjects(state.navigatorScope).compactMap(\.id))
        let all = model.activityLog.entries(matching: LogFilter(), projectIds: projectIDs)
        let entries = model.activityLog.entries(matching: filter, projectIds: projectIDs)
        let agents = Dictionary(all.compactMap { entry in entry.agentId.map { ($0, entry.source) } }, uniquingKeysWith: { first, _ in first })
        let steps = Array(Set(all.map(\.step).filter { !$0.isEmpty })).sorted()
        VStack(spacing: 0) {
            PanelToolbar {
                Menu(filter.agentId.flatMap { agents[$0] } ?? "All agents") {
                    Button("All agents") { filter.agentId = nil }
                    ForEach(agents.sorted { $0.value < $1.value }, id: \.key) { id, name in
                        Button(name) { filter.agentId = id }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                Menu(filter.step ?? "All steps") {
                    Button("All steps") { filter.step = nil }
                    ForEach(steps, id: \.self) { step in Button(step) { filter.step = step } }
                }
                .menuStyle(.button)
                .fixedSize()
                HStack(spacing: 2) {
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        let isOn = filter.levels.contains(level)
                        Button {
                            if isOn { filter.levels.remove(level) } else { filter.levels.insert(level) }
                        } label: {
                            Text(level.rawValue)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(isOn ? level.color : Theme.tertiaryText)
                                .frame(width: 20, height: 20)
                                .background(isOn ? level.color.opacity(0.18) : Color.white.opacity(0.05), in: .rect(cornerRadius: 5))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(level.title)
                        .accessibilityLabel(level.title)
                        .accessibilityValue(isOn ? "Shown" : "Hidden")
                    }
                }
                Spacer(minLength: 8)
                TextField("Filter: text, or /regex", text: $filter.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle(isOn: $follows) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Follow new lines")
                Button { model.activityLog.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Clear the log")
            }
            if entries.isEmpty {
                Text(all.isEmpty ? "Nothing yet. Run steps, agent tool calls, checks and holds show up here as they happen." : "No lines match the filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                LogLine(entry: entry).id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: entries.last?.id) { _, last in
                        if follows, let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

extension LogEntry.Level {
    var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .debug: Theme.info
        case .info: Theme.successText
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

private struct LogLine: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3))))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 92, alignment: .leading)
            Text(entry.level.rawValue).foregroundStyle(entry.level.color).fontWeight(.bold).frame(width: 12)
            Text(entry.source).lineLimit(1).frame(width: 110, alignment: .leading)
            Text(entry.step).foregroundStyle(Theme.secondaryText).lineLimit(1).frame(width: 90, alignment: .leading)
            Text(entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(entry.level == .warning ? Theme.warning.opacity(0.07) : entry.level == .error ? Theme.danger.opacity(0.08) : .clear)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
@Observable
final class TerminalSession {
    static var sessions: [String: TerminalSession] = [:]

    static func shared(for directory: URL) -> TerminalSession {
        if let existing = sessions[directory.path] { return existing }
        let session = TerminalSession(directory: directory)
        sessions[directory.path] = session
        return session
    }

    let directory: URL
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var history: [String] = []
    @ObservationIgnored private var process: Process?
    static let outputLimit = 400_000

    init(directory: URL) {
        self.directory = directory
    }

    func run(_ command: String, environment: [String: String]) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        history.append(trimmed)
        append("$ \(trimmed)\n")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", trimmed]
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.append(status == 0 ? "\n" : "\n[exit \(status)]\n")
                self?.isRunning = false
                self?.process = nil
            }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            append("Couldn’t run the command: \(error.localizedDescription)\n")
        }
    }

    func stop() {
        process?.interrupt()
    }

    func clear() {
        output = ""
    }

    private func append(_ text: String) {
        output += text
        if output.count > Self.outputLimit { output = String(output.suffix(Self.outputLimit)) }
    }
}

struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @State private var directory: URL?
    @State private var command = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if let project = model.currentProject {
            let places = terminalPlaces(project)
            let current = directory ?? places.first?.1 ?? project.url
            let session = TerminalSession.shared(for: current)
            VStack(spacing: 0) {
                PanelToolbar {
                    Picker("Worktree", selection: Binding(get: { current }, set: { directory = $0 })) {
                        ForEach(places, id: \.1) { name, url in Text(name).tag(url) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(current.path.abbreviatingHome).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Open in Terminal") { model.openInTerminal(current) }.buttonStyle(.borderless)
                    Button { session.clear() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Clear")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(session.output.isEmpty ? "Runs one shell command at a time in this worktree (zsh -lc). For interactive programs, open it in Terminal." : session.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(session.output.isEmpty ? Theme.tertiaryText : Theme.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("end")
                    }
                    .onChange(of: session.output) { proxy.scrollTo("end", anchor: .bottom) }
                }
                HStack(spacing: 8) {
                    Text("$").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.successText)
                    TextField(session.isRunning ? "Running…" : "Command", text: $command)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($isFocused)
                        .disabled(session.isRunning)
                        .onSubmit {
                            session.run(command, environment: model.locator.environment())
                            command = ""
                            isFocused = true
                        }
                        .onKeyPress(.upArrow) {
                            if let last = session.history.last { command = last }
                            return .handled
                        }
                    if session.isRunning {
                        Button("Stop") { session.stop() }.buttonStyle(PillButtonStyle(height: 22))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.black.opacity(0.25))
            }
        } else {
            Text("Open a project to run commands in its worktrees.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func terminalPlaces(_ project: Project) -> [(String, URL)] {
        [("Project checkout", project.url)] + model.state(for: project).worktrees
            .filter { $0.path.standardizedFileURL != project.url.standardizedFileURL }
            .map { (".crew/\($0.agent)", $0.path) }
    }
}

struct ChecksOutputPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @State private var selection: String?

    var body: some View {
        let _ = model.engine.runs
        let runs = model.runs(in: model.navigatorProjects(state.navigatorScope)).filter { ProjectSignals.activeStatuses.contains($0.status) }
        let board = ProjectSignals.checkBoard(runs: runs, steps: model.steps(of: runs), holds: model.engine.holds)
        let results = board.flatMap { entry in entry.results.map { (entry, $0) } }
        let selected = results.first { "\($0.0.id)|\($0.1.name)" == selection } ?? results.first { !$0.1.passed } ?? results.first
        if results.isEmpty {
            Text(board.isEmpty ? "No checks have run in an active run yet." : board.compactMap(\.message).first ?? "Checks are running.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                List(selection: Binding(get: { selected.map { "\($0.0.id)|\($0.1.name)" } }, set: { selection = $0 })) {
                    ForEach(results, id: \.1.id) { entry, result in
                        HStack(spacing: 6) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.passed ? Theme.successText : Theme.danger)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(result.name).font(.system(size: 12, weight: .semibold))
                                Text("\(entry.agentName ?? entry.runTitle) · round \(entry.round)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .tag("\(entry.id)|\(result.name)")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 240)
                Divider()
                ScrollView {
                    if let (_, result) = selected {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("$ \(result.command)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                            Text(output(of: result)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                }
            }
        }
    }

    private func output(of result: CheckResult) -> String {
        if let path = result.logPath, let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty {
            return String(text.suffix(200_000))
        }
        return result.output.isEmpty ? result.headline : result.output
    }
}

struct ProblemsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let rows = model.problems(scope: state.navigatorScope).map(ProblemRowModel.init)
        if rows.isEmpty {
            Text("No problems.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn("") { row in
                    Image(systemName: row.problem.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(row.problem.severity == .error ? Theme.danger : Theme.warning)
                        .accessibilityLabel(row.problem.severity == .error ? "Error" : "Warning")
                }
                .width(22)
                TableColumn("Problem") { row in
                    Text(row.problem.title).onTapGesture(count: 2) { model.open(row.problem, in: row.project, workbench: state) }
                }
                TableColumn("Kind") { row in Text(row.problem.category.title).foregroundStyle(Theme.secondaryText) }.width(110)
                TableColumn("Location") { row in Text(row.problem.location).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText) }
                TableColumn("Project") { row in Text(row.project.name).foregroundStyle(Theme.secondaryText) }.width(110)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: ProblemRowModel.ID.self) { _ in } primaryAction: { ids in
                if let row = rows.first(where: { ids.contains($0.id) }) { model.open(row.problem, in: row.project, workbench: state) }
            }
        }
    }
}

private struct ProblemRowModel: Identifiable {
    let project: Project
    let problem: ProjectProblem

    init(_ pair: (project: Project, problem: ProjectProblem)) {
        project = pair.project
        problem = pair.problem
    }

    var id: String { "\(project.id ?? -1)|\(problem.id)" }
}

struct ServersPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let servers = model.openProjects.flatMap { project in
            model.agentSessions(in: project).compactMap { session in session.agent.port.map { (project, session, $0) } }
        }
        if servers.isEmpty {
            Text("No dev server ports. Set a base port in Settings › Workspaces and each agent’s worktree gets its own.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(servers, id: \.1.id) { project, session, port in
                        let isListening = model.listeningPorts.contains(port)
                        HStack(spacing: 12) {
                            Circle().fill(isListening ? Theme.success : Theme.neutral).frame(width: 8, height: 8)
                            Text(":\(port)").font(.system(size: 12, design: .monospaced)).frame(width: 60, alignment: .leading)
                            Text(model.displayName(of: session.agent, in: project)).font(.system(size: 12, weight: .semibold)).frame(width: 140, alignment: .leading)
                            Text(session.agent.worktreePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(isListening ? "listening" : "not running").font(.system(size: 11.5)).foregroundStyle(isListening ? Theme.successText : Theme.secondaryText)
                            Button("Open") {
                                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(PillButtonStyle(height: 22))
                            .disabled(!isListening)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct ActivityPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let entries = model.backgroundActivity
            if entries.isEmpty {
                Text("No background work right now.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ActivityEntryRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

struct ActivityEntryRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.title).font(.system(size: 12.5)).lineLimit(1)
            Text(entry.detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Spacer(minLength: 8)
            if let progress = entry.progress {
                ProgressView(value: progress).frame(width: 80)
            }
            Text(entry.trailing).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

extension WorkbenchRegistry {
    func registerActivitySources() {
        register(ActivitySourceSpec(id: "clones", title: "Clones", order: 0) { model in
            model.activeClones.map { remote, started in
                ActivityEntry(id: "clone|\(remote)", title: "Cloning", detail: remote, trailing: "since \(started.formatted(date: .omitted, time: .shortened))")
            }
        })
        register(ActivitySourceSpec(id: "setup", title: "Setup scripts", order: 10) { model in
            model.openProjects.flatMap { project in
                model.agentSessions(in: project).filter { model.agents.isSettingUp($0) }.map { session in
                    ActivityEntry(id: "setup|\(session.id)", title: "Setup script", detail: "\(model.displayName(of: session.agent, in: project)) · \(project.name)", trailing: "running")
                }
            }
        })
        register(ActivitySourceSpec(id: "github", title: "GitHub polling", order: 20) { model in
            let poller = model.gitHub.poller
            return model.openProjects.compactMap { project -> ActivityEntry? in
                guard let id = project.id, project.settings.githubRepository != nil else { return nil }
                let trailing: String
                if poller.pollingProjects.contains(id) {
                    trailing = "polling now"
                } else if poller.isBackingOff(at: .now), let until = poller.backoffUntil {
                    trailing = "backing off until \(until.formatted(date: .omitted, time: .shortened))"
                } else if let last = poller.lastPolledAt[id] {
                    trailing = "last \(last.formatted(.relative(presentation: .named)))"
                } else {
                    trailing = "not polled yet"
                }
                return ActivityEntry(id: "github|\(id)", title: "GitHub polling", detail: [project.name, poller.lastErrors[id]].compactMap(\.self).joined(separator: " · "), trailing: trailing)
            }
        })
        register(ActivitySourceSpec(id: "cleanup", title: "Worktree cleanup", order: 30) { model in
            model.openProjects.compactMap { project -> ActivityEntry? in
                let minutes = project.settings.idleCleanupMinutes
                guard minutes > 0, model.idleCleanup.isRunning else { return nil }
                return ActivityEntry(id: "cleanup|\(project.id ?? -1)", title: "Worktree cleanup", detail: project.name, trailing: "idle agents removed after \(minutes) min")
            }
        })
    }
}
