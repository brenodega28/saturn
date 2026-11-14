import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChatCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat

    var body: some View {
        ChatCardRows(project: project, chat: chat)
            .padding(6)
            .frame(width: Tokens.Size.chatCard, alignment: .leading)
            .background(Tokens.card, in: .rect(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Tokens.hair2))
    }
}

struct ChatCardRows: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MachineRow(project: project)
            WorktreeButton(project: project)
            RunRow(project: project)
            OutputRow(project: project)
            ChangesRow(project: project, chat: chat)
            ChecksRow(project: project, chat: chat)
        }
        .font(.system(size: 13.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This chat’s project and app")
        .onChange(of: project.id) { model.isRunMenuOpen = false }
    }
}

struct ChatCardPill: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat
    @State private var isOpen = false

    var body: some View {
        let port = model.appRunner(for: project)?.state.ports.first
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                if let port { Text(verbatim: ":\(port)").font(Tokens.mono(12)) }
                Text("Checks")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Tokens.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("This chat’s project and app")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ChatCard(project: project, chat: chat)
        }
    }
}

private struct CardRow<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).frame(width: 16)
            Text(title).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(.rect)
    }
}

private struct MachineRow: View {
    let project: Project

    var body: some View {
        CardRow(symbol: project.isRemote ? "server.rack" : "laptopcomputer", title: project.isRemote ? project.location : Host.current().localizedName ?? "This Mac") {
            if project.isRemote {
                Text("SSH")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Tokens.fill2, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WorktreeButton: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        @Bindable var model = model
        let target = model.selectedRunTarget(in: project)
        Button { model.isRunMenuOpen.toggle() } label: {
            CardRow(symbol: "arrow.triangle.branch", title: target.branch) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.text2)
            }
            .font(Tokens.mono(12.5))
        }
        .buttonStyle(.plain)
        .help("Choose the worktree to run the app from")
        .accessibilityLabel("Run the app from \(target.branch)")
        .popover(isPresented: $model.isRunMenuOpen, arrowEdge: .leading) {
            RunTargetList(project: project, selected: target)
        }
    }
}

private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let target = model.selectedRunTarget(in: project)
        let runner = model.appRunner(for: project)
        let command = model.runCommand(for: project, in: target.folder)
        let state = runner?.state ?? .idle
        let isActive = runner?.isActive ?? false
        let runsSelected = runner?.isRunning(in: target.folder) ?? false
        HStack(spacing: 8) {
            Circle().fill(Self.dot(state)).frame(width: 7, height: 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(state, ports: state.ports, isRemote: project.isRemote))
                    .foregroundStyle(Tokens.text)
                if command == nil, !isActive {
                    Button("Tell Ensemble how to start this app") { model.openSettings(.workspaces, in: project) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.link)
                        .font(.system(size: 11.5))
                } else if let label = runner?.isActive == true ? runner?.label : command?.label {
                    Text(label).font(Tokens.mono(11)).foregroundStyle(Tokens.text2).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if isActive {
                Button { Task { await model.stopApp(in: project) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(RunButtonStyle(fill: Tokens.stuckBackground, text: Tokens.stuck))
                    .help("Stop the app and every process it started")
            }
            if !runsSelected {
                Button { Task { await model.startApp(target, in: project) } } label: {
                    Label(state.isFailed ? "Retry" : "Start", systemImage: state.isFailed ? "arrow.clockwise" : "play.fill")
                }
                .buttonStyle(RunButtonStyle(fill: Tokens.live, text: Color(hex: 0x04210D)))
                .disabled(command == nil)
                .help(command == nil ? "No run command found" : "Run \(command?.label ?? "") from \(target.branch)")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(Tokens.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    static func title(_ state: AppRunState, ports: [Int], isRemote: Bool) -> String {
        switch state {
        case .idle, .stopped(nil): "Stopped"
        case .stopped(let code?): "Exited with code \(code)"
        case .starting: "Starting…"
        case .running: ports.first.map { "Running · localhost:\($0)" } ?? "Running"
        case .failed: "Failed to start"
        }
    }

    static func dot(_ state: AppRunState) -> Color {
        switch state {
        case .running: Tokens.live
        case .starting: Tokens.build
        case .failed: Tokens.stuck
        case .stopped(let code?) where code != 0: Tokens.stuck
        case .idle, .stopped: Tokens.text3
        }
    }
}

private struct RunButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? text : Tokens.text3)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isEnabled ? fill.opacity(configuration.isPressed ? 0.8 : 1) : Tokens.fill, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

extension AppRunState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct OutputRow: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        @Bindable var model = model
        let lines = model.appOutput(in: project)
        Button { model.isAppOutputShown.toggle() } label: {
            CardRow(symbol: "text.alignleft", title: "Output") {
                Text(lines.isEmpty ? "Nothing yet" : "\(lines.count) line\(lines.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(lines.contains { $0.level == .error } ? Tokens.stuck : Tokens.text2)
            }
        }
        .buttonStyle(.plain)
        .help(model.isAppOutputShown ? "Hide the app’s output" : "Show the app’s output")
    }
}

private struct ChangesRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat
    @State private var diff: DiffInfo?

    var body: some View {
        let run = model.latestRun(of: chat)
        Button { model.open(.changes) } label: {
            CardRow(symbol: "plus.forwardslash.minus", title: "Changes") {
                if let diff, diff.lines > 0 {
                    Text("+\(diff.added.formatted())").font(Tokens.mono(12)).foregroundStyle(Tokens.done)
                    Text("−\(diff.deleted.formatted())").font(Tokens.mono(12)).foregroundStyle(Tokens.danger)
                } else {
                    Text("None yet").font(.system(size: 12)).foregroundStyle(Tokens.text2)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open Changes")
        .task(id: run.map { "\($0.id ?? 0)-\($0.status.rawValue)-\($0.currentStep ?? "")" } ?? "none") {
            if let run {
                diff = await model.diffInfo(run)
            } else {
                diff = nil
            }
        }
    }
}

private struct ChecksRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chat: Chat
    @State private var isExpanded = false

    var body: some View {
        let run = model.latestRun(of: chat)
        let checks = model.chatChecks(for: chat, run: run)
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                CardRow(symbol: "checkmark.square", title: "Checks") {
                    Text(Self.summary(checks.state)).font(.system(size: 12)).foregroundStyle(Self.color(checks.state))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.text2)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(checks.rows) { row in
                        HStack(spacing: 8) {
                            Text(Self.mark(row.status)).foregroundStyle(Self.color(row.status)).frame(width: 14)
                            Text(row.name).foregroundStyle(Tokens.text)
                            Spacer()
                            if row.durationSeconds > 0 {
                                Text(String(format: "%.1f s", row.durationSeconds)).font(Tokens.mono(11)).foregroundStyle(Tokens.text2)
                            }
                        }
                        .font(.system(size: 12.5))
                    }
                    if checks.rows.isEmpty {
                        Text(Self.note(checks.state)).font(.system(size: 12)).foregroundStyle(Tokens.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    if let run {
                        Button("Open run details →") { model.openRunDetail(run) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.link)
                            .padding(.top, 4)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 36, bottom: 10, trailing: 10))
            }
        }
    }

    static func summary(_ state: ChatChecks.State) -> String {
        switch state {
        case .waitingForWorkers: "Starts after workers"
        case .notStarted: "Not started"
        case .running(let round): "Round \(round) · running"
        case .failed(let round, let maxRounds): "Round \(round) of \(maxRounds) failed"
        case .exhausted(let round): "Round \(round) · out of retries"
        case .passed(let count): count > 0 ? "Passed · \(count) of \(count)" : "Passed"
        }
    }

    static func note(_ state: ChatChecks.State) -> String {
        switch state {
        case .waitingForWorkers: "Checks run on each worker’s branch once it says it’s done. This chat has no workers yet."
        case .notStarted: "Workers are still building."
        default: "No check results yet."
        }
    }

    static func color(_ state: ChatChecks.State) -> Color {
        switch state {
        case .failed, .exhausted: Tokens.stuck
        case .passed: Tokens.done
        case .running: Tokens.build
        case .waitingForWorkers, .notStarted: Tokens.text2
        }
    }

    static func mark(_ status: ChatChecks.Row.Status) -> String {
        switch status {
        case .passed: "✓"
        case .failed: "✕"
        case .running: "◌"
        }
    }

    static func color(_ status: ChatChecks.Row.Status) -> Color {
        switch status {
        case .passed: Tokens.done
        case .failed: Tokens.stuck
        case .running: Tokens.build
        }
    }
}

struct RunTargetList: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let selected: RunTarget

    var body: some View {
        let targets = model.runTargets(in: project)
        let runner = model.appRunner(for: project)
        VStack(alignment: .leading, spacing: 1) {
            Text("Run the app from").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Tokens.text2).padding(8)
            ForEach(targets) { target in
                let isSelected = target.id == selected.id
                Button {
                    model.selectRunTarget(target, in: project)
                    model.isRunMenuOpen = false
                    if runner?.isActive == true, runner?.isRunning(in: target.folder) == false {
                        Task {
                            await model.stopApp(in: project)
                            await model.startApp(target, in: project)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if let agent = target.agent {
                            AgentAvatar(size: 22, appearance: RoleAppearance(role: model.role(for: agent, in: project)))
                        } else {
                            Image(systemName: "laptopcomputer").frame(width: 22, height: 22).foregroundStyle(Tokens.text2)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.branch).font(Tokens.mono(12, weight: .semibold)).foregroundStyle(Tokens.text).lineLimit(1)
                            Text(target.who).font(.system(size: 11)).foregroundStyle(Tokens.text2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(runner?.isRunning(in: target.folder) == true ? "Running" : target.agent.map(\.status.label) ?? "Up to date")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(runner?.isRunning(in: target.folder) == true ? Tokens.done : Tokens.text2)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 42)
                    .background(isSelected ? Tokens.selection : .clear, in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Text("Only this chat’s worktrees are listed. Switching restarts the app.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.text2)
                .padding(8)
        }
        .padding(6)
        .frame(width: 380)
    }
}

struct AppOutputPanel: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let lines = model.appOutput(in: project)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Output").font(.system(size: 12.5, weight: .semibold))
                if let label = model.appRunner(for: project)?.label {
                    Text(label).font(Tokens.mono(11.5)).foregroundStyle(Tokens.text2).lineLimit(1)
                }
                Spacer()
                Button("Clear") { model.clearAppOutput(in: project) }.buttonStyle(.plain).foregroundStyle(Tokens.link)
                Button { model.isAppOutputShown = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.text2)
                    .accessibilityLabel("Close output")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider().overlay(Tokens.hair)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(Tokens.text3)
                            Text(entry.message).foregroundStyle(entry.level == .error ? Tokens.danger : Tokens.text).textSelection(.enabled)
                        }
                        .font(Tokens.mono(11.5))
                        .id(entry.id)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Tokens.code, in: .rect(cornerRadius: Tokens.Radius.popover, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.popover, style: .continuous).strokeBorder(Tokens.hair2))
    }
}
