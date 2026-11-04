import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunBar: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let target = model.selectedRunTarget(in: project)
        let runner = model.appRunner(for: project)
        let command = model.runCommand(for: project, in: target.folder)
        let state = runner?.state ?? .idle
        let isActive = runner?.isActive ?? false
        let runsSelected = runner?.isRunning(in: target.folder) ?? false
        HStack(spacing: 10) {
            BranchButton(target: target, isOpen: model.isRunMenuOpen) {
                model.isRunMenuOpen.toggle()
            }
            .overlay(alignment: .topLeading) {
                if model.isRunMenuOpen {
                    RunTargetList(project: project, selected: target)
                        .offset(y: 42)
                        .transition(.opacity)
                }
            }
            RunBarButton(title: "Start", glyph: .start, isEnabled: command != nil && !runsSelected, enabledFill: V4.green, enabledText: V4.onGreen) {
                model.isRunMenuOpen = false
                Task { await model.startApp(target, in: project) }
            }
            .help(command == nil ? "No run command found" : "Run \(command?.label ?? "") from \(target.branch)")
            RunBarButton(title: "Stop", glyph: .stop, isEnabled: isActive, enabledFill: V4.stopFill, enabledText: V4.denied) {
                model.isRunMenuOpen = false
                Task { await model.stopApp(in: project) }
            }
            .help("Stop the app and every process it started")
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 24)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
            RunStatus(project: project, state: state, branch: runner?.branch ?? target.branch, hasCommand: command != nil)
            if let port = state.ports.first {
                Button { model.openRunningApp(port: port) } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: "localhost:\(port)")
                        Text("↗").accessibilityHidden(true)
                    }
                    .font(V4.monospaced(12))
                    .foregroundStyle(V4.link)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(V4.blue.opacity(0.16), in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Open http://localhost:\(port) in your browser")
                .accessibilityLabel("Open localhost:\(port) in the browser")
            }
            if let label = runner?.isActive == true ? runner?.label : command?.label {
                Text(label)
                    .font(V4.monospaced(11.5))
                    .foregroundStyle(V4.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .fixedSize(horizontal: label.count < 28, vertical: false)
                    .help(command?.origin ?? "")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(V4.sidebarFill, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run the app")
        .onExitCommand { model.isRunMenuOpen = false }
        .onChange(of: project.id) { model.isRunMenuOpen = false }
    }
}

private struct BranchButton: View {
    let target: RunTarget
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RunTargetTile(target: target)
                VStack(alignment: .leading, spacing: 0) {
                    Text(target.branch)
                        .font(V4.monospaced(12.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(target.who)
                        .font(.system(size: 11))
                        .foregroundStyle(V4.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: 280, alignment: .leading)
                ChevronShape()
                    .stroke(V4.label.opacity(0.7), style: StrokeStyle(lineWidth: 2.6 * 10 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 10)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Branch to run: \(target.branch)")
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
        .help("Choose the checkout to run the app from")
    }
}

private struct RunTargetTile: View {
    @Environment(AppModel.self) private var model
    let target: RunTarget
    var showsGlyph = true

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(fill)
            .frame(width: 22, height: 22)
            .overlay {
                if showsGlyph {
                    BranchGlyph()
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.2 * 12 / 24, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                }
            }
            .accessibilityHidden(true)
    }

    private var fill: LinearGradient {
        guard let agent = target.agent, let project = model.project(withID: agent.projectId) else { return V4.youGradient }
        return RoleAppearance(role: model.role(for: agent, in: project)).palette.gradient
    }
}

private struct RunTargetList: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let selected: RunTarget

    var body: some View {
        let targets = model.runTargets(in: project)
        let workers = targets.filter { !$0.isMain }
        let runner = model.appRunner(for: project)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                header("Main")
                ForEach(targets.filter(\.isMain)) { row($0, runner: runner) }
                header("Workers")
                if workers.isEmpty {
                    Text("No agents with a worktree in this project")
                        .font(.system(size: 11))
                        .foregroundStyle(V4.secondary)
                        .padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                }
                ForEach(workers) { row($0, runner: runner) }
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 400)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 40 / 255, green: 40 / 255, blue: 46 / 255).opacity(0.97), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 25, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branches")
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(V4.secondary)
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 3, trailing: 8))
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ target: RunTarget, runner: AppRunner?) -> some View {
        let isSelected = target.id == selected.id
        let status = statusWord(for: target, runner: runner)
        return Button {
            model.selectRunTarget(target, in: project)
            model.isRunMenuOpen = false
        } label: {
            HStack(spacing: 10) {
                RunTargetTile(target: target, showsGlyph: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.branch)
                        .font(V4.monospaced(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(target.who)
                        .font(.system(size: 11))
                        .foregroundStyle(V4.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(status.word)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.color)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .background(isSelected ? V4.selected : .clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(target.branch), \(target.who), \(status.word)")
    }

    private func statusWord(for target: RunTarget, runner: AppRunner?) -> (word: String, color: Color) {
        if runner?.isRunning(in: target.folder) == true { return ("Running", V4.greenText) }
        guard let agent = target.agent else { return ("Checked out", V4.secondary) }
        return (agent.status.label, agent.status.color)
    }
}

private struct RunStatus: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let state: AppRunState
    let branch: String
    let hasCommand: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if case .running = state {
                    Circle().fill(V4.green.opacity(0.2)).frame(width: 14, height: 14)
                }
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
            if !hasCommand, !state.isActive {
                Text("No run command found.")
                    .foregroundStyle(V4.label.opacity(0.82))
                Button("Set one in Settings › Workspaces") {
                    model.openSettings(.workspaces, in: project)
                }
                .buttonStyle(.plain)
                .foregroundStyle(V4.link)
                .help("Open Settings › Workspaces to set a run command")
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(detail(at: context.date))
                        .foregroundStyle(V4.label.opacity(0.82))
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state {
        case .idle, .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    private var dotColor: Color {
        switch state {
        case .running: V4.green
        case .starting: V4.blue
        case .failed: V4.red
        case .stopped(let code?) where code != 0: V4.red
        case .idle, .stopped: V4.label.opacity(0.4)
        }
    }

    private func detail(at now: Date) -> String {
        switch state {
        case .idle, .stopped(nil):
            return "Pick a branch and press Start to run the app from it"
        case .stopped(let code?):
            return "\(branch) · exited with code \(code)"
        case .starting:
            return "\(branch) · waiting for the server to listen"
        case .running(let ports, let since):
            let minutes = Int(now.timeIntervalSince(since) / 60)
            let uptime = minutes < 1 ? "up <1 min" : "up \(minutes) min"
            let listening = ports.map { ":\($0)" }.joined(separator: ", ")
            return ([branch, uptime] + (listening.isEmpty ? [] : [listening])).joined(separator: " · ")
        case .failed(let message):
            return message
        }
    }
}

private struct RunBarButton: View {
    enum Glyph {
        case start
        case stop
    }

    let title: String
    let glyph: Glyph
    let isEnabled: Bool
    let enabledFill: Color
    let enabledText: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    switch glyph {
                    case .start: PlayShape().frame(width: 12, height: 12)
                    case .stop: RoundedRectangle(cornerRadius: 11 * 3 / 24).frame(width: 11 * 16 / 24, height: 11 * 16 / 24).frame(width: 11, height: 11)
                    }
                }
                .accessibilityHidden(true)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? enabledText : V4.label.opacity(0.4))
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .frame(height: 34)
            .background(isEnabled ? enabledFill : Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct PlayShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        var path = Path()
        path.move(to: point(7, 4.5))
        path.addLine(to: point(7, 19.5))
        path.addQuadCurve(to: point(8.5, 20.36), control: point(7, 20.9))
        path.addLine(to: point(21, 12.86))
        path.addQuadCurve(to: point(21, 11.14), control: point(22.4, 12))
        path.addLine(to: point(8.5, 3.64))
        path.addQuadCurve(to: point(7, 4.5), control: point(7, 3.1))
        path.closeSubpath()
        return path
    }
}

private struct ChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 6 * scale, y: rect.minY + 9 * scale))
        path.addLine(to: CGPoint(x: rect.minX + 12 * scale, y: rect.minY + 15 * scale))
        path.addLine(to: CGPoint(x: rect.minX + 18 * scale, y: rect.minY + 9 * scale))
        return path
    }
}

private struct BranchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        func circle(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: rect.minX + (x - 3) * scale, y: rect.minY + (y - 3) * scale, width: 6 * scale, height: 6 * scale)
        }
        var path = Path()
        path.move(to: point(6, 3))
        path.addLine(to: point(6, 15))
        path.addEllipse(in: circle(18, 6))
        path.addEllipse(in: circle(6, 18))
        path.move(to: point(18, 9))
        path.addArc(center: point(9, 9), radius: 9 * scale, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        return path
    }
}
