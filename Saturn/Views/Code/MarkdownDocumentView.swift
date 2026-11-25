import SaturnCore
import SaturnUI
import SwiftUI

enum MarkdownReaderMode: String, CaseIterable, Identifiable {
    case rendered
    case source

    var id: Self { self }

    var title: String {
        switch self {
        case .rendered: "Rendered"
        case .source: "Source"
        }
    }
}

struct MarkdownDocumentView: View {
    let text: String
    var fontSize: CGFloat = 14

    var body: some View {
        let document = MarkdownFrontMatter.split(text)
        let blocks = MarkdownParser.blocks(document.body)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !document.fields.isEmpty {
                    MarkdownFrontMatterHeader(fields: document.fields, fontSize: fontSize)
                        .padding(.bottom, 4)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, fontSize: fontSize, caret: false)
                }
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CodeStyle.background)
    }
}

private struct MarkdownFrontMatterHeader: View {
    let fields: [(key: String, value: String)]
    let fontSize: CGFloat

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(fields.indices, id: \.self) { index in
                GridRow {
                    Text(fields[index].key)
                        .font(.system(size: fontSize - 2, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(fields[index].value.isEmpty ? "—" : fields[index].value)
                        .font(.system(size: fontSize - 1.5))
                        .foregroundStyle(fields[index].value.isEmpty ? Theme.tertiaryText : Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Front matter")
    }
}
