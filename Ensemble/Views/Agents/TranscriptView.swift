import EnsembleCore
import EnsembleUI
import SwiftUI

struct TranscriptView: View {
    let session: AgentSession

    var body: some View {
        let entries = session.transcript.entries
        let root = session.transcript.session?.cwd ?? session.agent.worktreePath
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        EntryView(entry: entry, root: root)
                            .id(entry.id)
                    }
                    if session.isRunning {
                        WorkingIndicator(tool: session.transcript.activeTool, root: root, isStopping: session.isStopping)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .card(cornerRadius: 20)
            .onChange(of: entries.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct EntryView: View {
    let entry: TranscriptEntry
    let root: String?

    var body: some View {
        switch entry.content {
        case .user(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Text(text).font(.system(size: 13.5)).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
        case .assistant(let text):
            Text(Self.markdown(text))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let tool):
            ToolRow(tool: tool, root: root)
        case .interrupted:
            NoticeView(text: "Interrupted", color: Theme.warning)
        case .notice(let notice, let detail):
            NoticeView(text: Self.text(for: notice, detail: detail), color: notice == .failed ? Theme.danger : Theme.secondaryText)
        case .turnFinished(let result):
            NoticeView(text: Self.summary(of: result), color: Theme.tertiaryText)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func text(for notice: EnsembleNotice, detail: String?) -> String {
        let base = switch notice {
        case .started: "Started"
        case .paused: "Paused"
        case .resumed: "Resumed"
        case .stopped: "Stopped"
        case .restarted: "Restarted with a fresh session"
        case .interrupted: "Interrupted"
        case .takenOver: "You took over the worktree"
        case .handedBack: "Handed back to the agent"
        case .failed: "Failed"
        }
        return detail.map { "\(base) · \($0)" } ?? base
    }

    static func summary(of result: TurnResult) -> String {
        let seconds = Double(result.durationMS) / 1000
        let tokens = result.usage.total.formatted(.number.notation(.compactName))
        let status = result.wasInterrupted ? "Turn interrupted" : (result.isError ? "Turn failed" : "Turn finished")
        return "\(status) · \(tokens) tokens · \(seconds.formatted(.number.precision(.fractionLength(1))))s"
    }
}

private struct NoticeView: View {
    let text: String
    let color: Color

    var body: some View {
        HStack {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

private struct ToolRow: View {
    let tool: ToolActivity
    let root: String?
    @State private var isExpanded = false

    var body: some View {
        let diff = tool.diff
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    Text(tool.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.link)
                        .frame(minWidth: 44, alignment: .leading)
                    Text(tool.target(relativeTo: root))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    status
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tool.name) \(tool.target(relativeTo: root))")

            if let diff, !tool.isError {
                DiffBlock(lines: diff)
            }
            if isExpanded, let result = tool.result, !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(tool.isError ? Theme.danger : Theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .background(Color.black.opacity(0.2))
            }
        }
        .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 10, style: .continuous))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }

    private var failureLabel: String {
        let result = tool.result ?? ""
        if result.isEmpty || result.contains("doesn't want to proceed") { return "Cancelled" }
        if result.contains("denied") { return "Denied" }
        return "Error"
    }

    @ViewBuilder
    private var status: some View {
        if !tool.isFinished {
            ProgressView().controlSize(.mini)
        } else if tool.isError {
            Text(failureLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.danger)
        } else {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.successText)
        }
    }
}

struct DiffBlock: View {
    let lines: [DiffLine]
    var maximumLines = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(maximumLines).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(Self.marker(line.kind)).frame(width: 10, alignment: .center)
                    Text(line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Self.color(line.kind))
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .background(Self.background(line.kind))
            }
            if lines.count > maximumLines {
                Text("\(lines.count - maximumLines) more lines")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    static func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Theme.successText
        case .removed: Color(hex: 0xFF8A80)
        case .context: Theme.secondaryText
        }
    }

    static func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Theme.success.opacity(0.1)
        case .removed: Theme.danger.opacity(0.1)
        case .context: .clear
        }
    }
}

private struct WorkingIndicator: View {
    let tool: ToolActivity?
    let root: String?
    let isStopping: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var text: String {
        if isStopping { return "Stopping…" }
        guard let tool else { return "Thinking…" }
        return "Running \(tool.name) \(tool.target(relativeTo: root))"
    }
}
