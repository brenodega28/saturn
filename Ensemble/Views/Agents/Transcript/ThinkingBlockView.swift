import EnsembleCore
import EnsembleUI
import SwiftUI

struct ThinkingBlockView: View {
    let block: ThinkingBlock
    @State private var manualExpansion: Bool?

    private var isExpanded: Bool { manualExpansion ?? !block.isFinished }
    private var hasText: Bool { !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { manualExpansion = !isExpanded }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.memory)
                        .symbolEffect(.pulse, isActive: !block.isFinished)
                        .accessibilityHidden(true)
                    Text(block.isFinished ? "Thought" : "Thinking…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    ThinkingMeta(block: block)
                    if hasText {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(Theme.tertiaryText)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .accessibilityValue(hasText ? (isExpanded ? "Expanded" : "Collapsed") : "")
            if isExpanded, hasText {
                Text(block.text)
                    .font(.system(size: 12.5))
                    .italic()
                    .lineSpacing(2)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.memory.opacity(0.35)).frame(width: 2) }
            }
        }
        .onChange(of: block.isFinished) { _, finished in
            if finished { withAnimation(.snappy(duration: 0.25)) { manualExpansion = nil } }
        }
    }
}

struct ThinkingMeta: View {
    let block: ThinkingBlock

    var body: some View {
        HStack(spacing: 6) {
            if let start = block.startedAt {
                ElapsedLabel(start: start, end: block.isFinished ? (block.finishedAt ?? start) : nil, prefix: block.isFinished ? "for " : "")
            }
            if let tokens = block.estimatedTokens, tokens > 0 {
                Text("· \(LiveFormat.tokens(tokens))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .contentTransition(.numericText())
            }
        }
    }
}
