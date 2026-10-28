import EnsembleCore
import EnsembleUI
import SwiftUI

struct ContextPreview: View {
    let context: RoleContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What an agent loads").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("≈ \(context.totalTokens.formatted()) tokens")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            if context.sections.isEmpty {
                Text("Nothing beyond Ensemble’s own instructions.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(context.sections) { section in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(for: section.kind))
                        .frame(width: 18)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(section.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if let source = section.source {
                                Text(source)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if section.isTruncated {
                                Chip(text: "truncated", foreground: Theme.warning, background: Theme.warning.opacity(0.12))
                                    .fixedSize()
                            }
                            Spacer(minLength: 8)
                            Text("\(section.tokens.formatted()) tokens")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize()
                        }
                        Text(section.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(3)
                    }
                }
            }
            ForEach(context.warnings) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Warning")
                    Text(warning.message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }

    private func symbol(for kind: RoleContext.SectionKind) -> String {
        switch kind {
        case .prompt: "text.quote"
        case .fileDoc: "doc.text"
        case .promptDoc: "text.bubble"
        case .skills: "sparkles"
        }
    }
}
