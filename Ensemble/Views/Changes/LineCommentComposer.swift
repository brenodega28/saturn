import EnsembleCore
import EnsembleUI
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
                    .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
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
    let selection: LineSelection
    let entry: BranchFileDiff
    let file: String
    let run: Run
    let store: ChangesStore

    var body: some View {
        LineCommentComposer(
            caption: "Comment on \(selection.side == .old ? "removed " : "")line\(selection.range.count == 1 ? "" : "s") \(rangeLabel)",
            onSave: { text in
                model.addComment(in: run, branchAgentId: entry.agentId, file: file, side: selection.side, lines: selection.range, text: text)
                store.clearLineSelection()
            },
            onCancel: store.clearLineSelection
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 760, alignment: .leading)
        .background(DiffPalette.pinCard, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.45)))
        .padding(EdgeInsets(top: 10, leading: store.layout == .split ? 70 : 52, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffPalette.selection.opacity(0.5))
    }

    private var rangeLabel: String {
        let range = selection.range
        return range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
    }
}
