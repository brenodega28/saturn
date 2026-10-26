import EnsembleCore
import EnsembleUI
import SwiftUI

struct TranscriptItemView: View {
    let item: TranscriptItem
    let root: String?

    var body: some View {
        switch item {
        case .entry(let entry): TranscriptEntryView(entry: entry, root: root)
        case .group(let group): ToolGroupRow(group: group, root: root)
        case .subagent(let entry, let children):
            if case .tool(let tool) = entry.content {
                SubagentCard(tool: tool, root: root, children: children)
            } else {
                TranscriptEntryView(entry: entry, root: root)
            }
        }
    }
}

struct TranscriptEntryView: View {
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
            MarkdownText(text: text, isStreaming: entry.isStreaming)
        case .thinking(let block):
            ThinkingBlockView(block: block)
        case .tool(let tool):
            TranscriptToolRow(tool: tool, root: root)
        case .interrupted:
            TranscriptNotice(text: "Interrupted", color: Theme.warning)
        case .notice(let notice, let detail):
            TranscriptNotice(text: Self.text(for: notice, detail: detail), color: notice == .failed ? Theme.danger : Theme.secondaryText)
        case .turnFinished(let result):
            TranscriptNotice(text: Self.summary(of: result), color: Theme.tertiaryText)
        }
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

struct TranscriptNotice: View {
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

struct SessionActivityView: View {
    let activity: SessionActivity
    let name: String
    let root: String?
    var fontSize: CGFloat = 14

    var body: some View {
        switch activity {
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(name) is working…").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
        case .replying(let text):
            MarkdownText(text: text, fontSize: fontSize, isStreaming: true)
        case .thinking(let block):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.memory)
                        .symbolEffect(.pulse)
                        .accessibilityHidden(true)
                    Text("Thinking…").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    ThinkingMeta(block: block)
                }
                if !block.text.isEmpty {
                    Text(block.text.suffix(400))
                        .font(.system(size: 12.5))
                        .italic()
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(3, reservesSpace: false)
                        .truncationMode(.head)
                }
            }
        case .tool(let tool):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tool.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.link)
                Text(tool.target(relativeTo: root))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let start = tool.startedAt { ElapsedLabel(start: start) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct FollowsBottom<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follows = true
    @State private var phase: ScrollPhase = .idle

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self, of: Self.isNearBottom) { _, near in
                if Self.isUserDriven(phase) { follows = near }
            }
            .onScrollPhaseChange { old, new, context in
                phase = new
                if new == .idle, Self.isUserDriven(old) { follows = Self.isNearBottom(context.geometry) }
            }
            .onChange(of: value) {
                guard follows, !Self.isUserDriven(phase) else { return }
                position.scrollTo(edge: .bottom)
            }
    }

    static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    static func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 48
    }
}

extension View {
    func followsBottom(of value: some Equatable) -> some View {
        modifier(FollowsBottom(value: value))
    }
}
