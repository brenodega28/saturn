import AppKit
import SaturnCore
import SaturnUI
import Observation
import SwiftTerm
import SwiftUI

struct TerminalLaunch: Hashable {
    let executable: String
    let arguments: [String]
    let directory: String?
    let shellName: String

    static func local(in directory: String) -> TerminalLaunch {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let exists = FileManager.default.fileExists(atPath: directory)
        return TerminalLaunch(executable: shell, arguments: ["-l"], directory: exists ? directory : NSHomeDirectory(), shellName: (shell as NSString).lastPathComponent)
    }

    static func remote(host: String, directory: String) -> TerminalLaunch {
        TerminalLaunch(
            executable: "/usr/bin/ssh",
            arguments: ["-t", host, "cd \(ShellQuote.quote(directory)) && exec $SHELL -l"],
            directory: NSHomeDirectory(),
            shellName: "ssh"
        )
    }

    var environment: [String] {
        var values = ProcessInfo.processInfo.environment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = "Saturn"
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }
        return values.map { "\($0.key)=\($0.value)" }
    }
}

@MainActor
@Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    let launch: TerminalLaunch
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var isRunning = false
    private(set) var exitCode: Int32?

    init(launch: TerminalLaunch) {
        self.launch = launch
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.autoresizingMask = [.width, .height]
        start()
    }

    var processID: pid_t { view.process.shellPid }

    private func start() {
        exitCode = nil
        isRunning = true
        view.startProcess(
            executable: launch.executable, args: launch.arguments, environment: launch.environment,
            execName: launch.shellName == "ssh" ? nil : "-\(launch.shellName)", currentDirectory: launch.directory
        )
    }

    func terminate() {
        let pid = processID
        guard isRunning, pid > 0 else { return }
        isRunning = false
        kill(pid, SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            columns = newCols
            rows = newRows
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            isRunning = false
            self.exitCode = exitCode
        }
    }
}

@MainActor
@Observable
final class TerminalStore {
    @ObservationIgnored private var sessions: [UUID: TerminalSession] = [:]
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    private var restarts = 0

    init() {
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    func session(for id: UUID, launch: TerminalLaunch) -> TerminalSession {
        _ = restarts
        if let session = sessions[id] { return session }
        let session = TerminalSession(launch: launch)
        sessions[id] = session
        return session
    }

    func restart(_ id: UUID) {
        guard let old = sessions[id] else { return }
        old.terminate()
        sessions[id] = TerminalSession(launch: old.launch)
        restarts += 1
    }

    func terminate(_ id: UUID) {
        sessions.removeValue(forKey: id)?.terminate()
    }

    func terminateAll() {
        for session in sessions.values { session.terminate() }
        sessions = [:]
    }
}

struct TerminalPage: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let pageID: UUID
    let project: Project
    let directory: String

    var body: some View {
        let session = model.terminals.session(for: pageID, launch: workspace.terminalLaunch(for: project, in: directory))
        VStack(spacing: 0) {
            PageHeader {
                Image(systemName: "terminal").font(.system(size: 12)).accessibilityHidden(true)
                Text(workspace.terminalPlace(directory, in: project)).font(Tokens.mono(12.5)).foregroundStyle(Tokens.text)
                if let branch = workspace.branch(at: directory, in: project) {
                    Text("·")
                    Text(branch).font(Tokens.mono(12.5)).lineLimit(1).truncationMode(.middle)
                }
                if project.isRemote || workspace.connection.isRemote {
                    Text("SSH")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tokens.build)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Tokens.buildBackground, in: Capsule())
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(session.launch.shellName) · \(session.columns)×\(session.rows)")
            }
            TerminalSurface(session: session)
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 6, trailing: 6))
                .background(Tokens.code)
                .overlay(alignment: .bottom) {
                    if !session.isRunning {
                        TerminalExitedBar(exitCode: session.exitCode) { model.terminals.restart(pageID) }
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal in \(directory)")
    }
}

private struct TerminalExitedBar: View {
    let exitCode: Int32?
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(exitCode.map { "The shell exited with code \($0)." } ?? "The shell exited.")
                .foregroundStyle(Tokens.text2)
            Spacer()
            Button("Restart", action: restart).buttonStyle(SecondaryPillStyle())
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Tokens.card)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }
}

struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
        let terminal = session.view
        let environment = context.environment
        terminal.nativeBackgroundColor = Self.color(Tokens.code, in: environment)
        terminal.nativeForegroundColor = Self.color(Tokens.text, in: environment)
        terminal.caretColor = Self.color(Tokens.text, in: environment)
        terminal.selectedTextBackgroundColor = Self.color(Tokens.fill2, in: environment)
        let font = Self.font
        if terminal.font != font { terminal.font = font }
    }

    private func attach(to container: NSView) {
        let terminal = session.view
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = container.bounds
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }

    static var font: NSFont {
        .monospacedSystemFont(ofSize: CGFloat(CodeStyle.fontSize + 0.5), weight: .regular)
    }

    static func color(_ color: SwiftUI.Color, in environment: EnvironmentValues) -> NSColor {
        NSColor(cgColor: color.resolve(in: environment).cgColor) ?? .textColor
    }
}

struct PageHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 12.5))
            .foregroundStyle(Tokens.text2)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }
}

extension DaemonWorkspace {
    func terminalLaunch(for project: Project, in directory: String) -> TerminalLaunch {
        if let host = project.host ?? (connection.isRemote ? connection.destination : nil) {
            return .remote(host: host, directory: directory)
        }
        return .local(in: directory)
    }

    func branch(at directory: String, in project: Project) -> String? {
        let path = (directory as NSString).standardizingPath
        if path == (project.path as NSString).standardizingPath { return state(for: project).branch }
        return agentSessions(in: project).map(\.agent).first { $0.worktreePath.map { ($0 as NSString).standardizingPath } == path }?.branch
    }
}
