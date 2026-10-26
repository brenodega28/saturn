import EnsembleCore
import EnsembleUI
import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession

    var body: some View {
        let transcript = session.transcript
        let entries = transcript.entries
        let live = transcript.liveEntry
        let items = TranscriptLayout.items(entries, live: live)
        let root = transcript.session?.cwd ?? session.agent.worktreePath
        let activity = TranscriptLayout.activity(entries, live: live)
        let todos = TranscriptLayout.latestTodos(in: entries)
        VStack(spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        TranscriptItemView(item: item, root: root)
                            .id(item.id)
                    }
                    if session.isRunning, session.isStopping || activity == .working {
                        WorkingIndicator(isStopping: session.isStopping)
                    }
                    Color.clear.frame(height: 1)
                }
                .padding(16)
            }
            .followsBottom(of: FollowSignature(count: entries.count, tail: live ?? entries.last, isRunning: session.isRunning))
            .card(cornerRadius: 20)
            if !todos.isEmpty {
                TodoChecklist(todos: todos)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: todos.isEmpty)
        .opensCodeFiles(in: session.agent.projectId, root: root, model: model)
    }
}

struct FollowSignature: Equatable {
    let count: Int
    let tail: TranscriptEntry?
    let isRunning: Bool
}

private struct WorkingIndicator: View {
    let isStopping: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(isStopping ? "Stopping…" : "Working…").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
