import SaturnCore
import SaturnUI
import SwiftUI

struct LineCommentComposer: View {
    let caption: String?
    let saveTitle: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(caption: String? = nil, text: String = "", saveTitle: String = "Request change", onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.caption = caption
        self.saveTitle = saveTitle
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: text)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 8) {
                TextField("What should change?", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Tokens.window, in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair2))
                    .focused($isFocused)
                    .onSubmit(save)
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }
                Button(saveTitle, action: save)
                    .buttonStyle(PillButtonStyle(.primary, height: 30))
                    .disabled(trimmed.isEmpty)
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle(height: 30))
            }
            .font(.system(size: 12.5))
        }
        .fontDesign(.default)
        .textSelection(.disabled)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

struct NewLineComment: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let selection: LineSelection
    let entry: BranchFileDiff
    let file: String
    let run: Run
    let store: ChangesStore

    var body: some View {
        LineCommentComposer(
            caption: "Comment on \(selection.side == .old ? "removed " : "")line\(selection.range.count == 1 ? "" : "s") \(rangeLabel)",
            onSave: { text in
                workspace.addComment(in: run, branchAgentId: entry.agentId, file: file, side: selection.side, lines: selection.range, text: text)
                store.clearLineSelection()
            },
            onCancel: store.clearLineSelection
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Tokens.raised, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.accent.opacity(0.34)))
        .padding(EdgeInsets(top: 6, leading: 64, bottom: 8, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangeLabel: String {
        let range = selection.range
        return range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
    }
}
