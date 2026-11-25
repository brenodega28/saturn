import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct DevServerRow: View {
    static let pollInterval: Duration = .seconds(3)

    let port: Int
    @State private var isListening: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(dotColor, size: 8)
                    .padding(3)
                    .background(dotColor.opacity(isListening == true ? 0.2 : 0), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dev server")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Text(verbatim: "localhost:\(port)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Open") {
                    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .help("Open localhost:\(port) in your browser")
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Dev server on localhost port \(port), \(statusText)")

            if isListening == false {
                Text("Nothing is listening on \(String(port)) yet. Agents get it as $PORT; ask this one to start the dev server.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: port) {
            while !Task.isCancelled {
                isListening = await PortProbe.isListening(port: port)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private var dotColor: Color {
        switch isListening {
        case true?: Theme.success
        case false?: Theme.neutral
        case nil: Theme.tertiaryText
        }
    }

    private var statusText: String {
        switch isListening {
        case true?: "running"
        case false?: "nothing listening"
        case nil: "checking"
        }
    }
}

struct SetupLogSection: View {
    static let maximumLogBytes = 64 * 1024

    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let session: LiveAgentSession
    @State private var record: SetupRecord?
    @State private var log = ""
    @State private var isExpanded = false

    var body: some View {
        let isSettingUp = session.isSettingUp
        VStack(alignment: .leading, spacing: 0) {
            if record != nil || isSettingUp {
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        ScrollView {
                            Text(log.isEmpty ? "No output yet." : log)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(log.isEmpty ? Theme.tertiaryText : Theme.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 220)
                        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            Text("Setup").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if isSettingUp {
                                ProgressView().controlSize(.mini)
                            }
                            Text(summary(isSettingUp: isSettingUp))
                                .font(.system(size: 11))
                                .foregroundStyle(summaryColor(isSettingUp: isSettingUp))
                        }
                    }
                    .help("Output of the project’s setup script for this worktree")

                    if session.setupFailed {
                        Button("Retry Setup") { session.retrySetup() }
                            .buttonStyle(.pill)
                            .help("Run the setup script again in this worktree")
                    }
                }
            }
        }
        .task(id: "\(session.id)-\(isSettingUp)-\(session.agent.status.rawValue)") {
            await follow(isSettingUp: isSettingUp)
        }
    }

    private func follow(isSettingUp: Bool) async {
        repeat {
            await reload()
            if isSettingUp || record?.status == .failed || record?.status == .timedOut { isExpanded = true }
            guard isSettingUp else { return }
            try? await Task.sleep(for: .seconds(1))
        } while !Task.isCancelled
    }

    private func reload() async {
        let connection = workspace.connection
        let agentID = session.id
        record = (try? await connection.fileData(.agentFile, id: "\(agentID)/\(SetupRecord.recordFileName)"))
            .flatMap(SetupRecord.decoded(from:))
        guard let data = try? await connection.fileData(.agentFile, id: "\(agentID)/\(SetupRecord.logFileName)") else {
            log = ""
            return
        }
        log = String(decoding: data.suffix(Self.maximumLogBytes), as: UTF8.self)
    }

    private func summary(isSettingUp: Bool) -> String {
        if isSettingUp { return "Running…" }
        guard let record else { return "" }
        switch record.status {
        case .running: return "Interrupted"
        case .succeeded: return record.endedAt.map { "Done in \(Self.elapsed(from: record.startedAt, to: $0))" } ?? "Done"
        case .failed: return record.exitCode.map { "Failed · exit \($0)" } ?? "Failed"
        case .timedOut: return "Timed out"
        }
    }

    private func summaryColor(isSettingUp: Bool) -> Color {
        guard !isSettingUp, let record else { return Theme.secondaryText }
        switch record.status {
        case .succeeded: return Theme.successText
        case .failed, .timedOut: return Theme.danger
        case .running: return Theme.warning
        }
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
