import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct MarkdownText: View {
    let text: String
    var fontSize: CGFloat = 13.5
    var isStreaming = false

    var body: some View {
        let blocks = MarkdownParser.blocks(text)
        VStack(alignment: .leading, spacing: 10) {
            MarkdownBlocksView(blocks: blocks, fontSize: fontSize, caret: isStreaming)
            if isStreaming, blocks.last.map(Self.hostsCaret) != true {
                StreamingCaret(fontSize: fontSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func hostsCaret(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading, .list: true
        default: false
        }
    }

    static func inline(_ text: String) -> AttributedString {
        linkingChatLinks((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    static func linkingChatLinks(_ text: AttributedString) -> AttributedString {
        let plain = String(text.characters)
        guard plain.localizedCaseInsensitiveContains(ChatLink.scheme + "://") else { return text }
        var linked = text
        for match in plain.matches(of: chatLinkPattern) {
            guard let link = ChatLink(string: String(plain[match.range])) else { continue }
            let start = linked.characters.index(linked.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: match.range.lowerBound))
            let end = linked.characters.index(start, offsetBy: plain.distance(from: match.range.lowerBound, to: match.range.upperBound))
            guard linked[start..<end].runs.allSatisfy({ $0.link == nil }) else { continue }
            linked[start..<end].link = link.url
        }
        return linked
    }

    private static var chatLinkPattern: Regex<Substring> { /(?i)ensemble:\/\/chat\/\d+(?:\?message=\d+)?/ }

    static func caret(size: CGFloat) -> AttributedString {
        var caret = AttributedString(" ▍")
        caret.foregroundColor = Theme.accent
        caret.font = .system(size: size)
        return caret
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let fontSize: CGFloat
    var caret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                MarkdownBlockView(block: block, fontSize: fontSize, caret: caret && offset == blocks.count - 1)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat
    let caret: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(withCaret(MarkdownText.inline(text)))
                .font(.system(size: fontSize + Self.headingBoost(level), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(withCaret(MarkdownText.inline(text)))
                .font(.system(size: fontSize))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .list(_, let items):
            MarkdownListView(items: items, fontSize: fontSize, caret: caret)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.secondaryText.opacity(0.5)).frame(width: 3)
                AnyView(MarkdownBlocksView(blocks: blocks, fontSize: fontSize))
                    .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, let isClosed):
            CodeBlockView(code: code, language: language, isStreaming: !isClosed)
        case .table(let header, let alignments, let rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows, fontSize: fontSize)
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func withCaret(_ text: AttributedString) -> AttributedString {
        caret ? text + MarkdownText.caret(size: fontSize) : text
    }

    static func headingBoost(_ level: Int) -> CGFloat {
        switch level {
        case 1: 6
        case 2: 4
        case 3: 2
        default: 0.5
        }
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let fontSize: CGFloat
    let caret: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    marker(item)
                    Text(offset == items.count - 1 && caret ? MarkdownText.inline(item.text) + MarkdownText.caret(size: fontSize) : MarkdownText.inline(item.text))
                        .font(.system(size: fontSize))
                        .lineSpacing(3)
                        .strikethrough(item.isChecked == true, color: Theme.tertiaryText)
                        .opacity(item.isChecked == true ? 0.6 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * 18)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownListItem) -> some View {
        if let checked = item.isChecked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(checked ? Theme.successText : Theme.secondaryText)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if let number = item.number {
            Text("\(number).")
                .font(.system(size: fontSize).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text(item.depth == 0 ? "•" : "◦")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 10)
        }
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], weight: .semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                .background(Theme.fillRaised)
                ForEach(rows.indices, id: \.self) { row in
                    Divider().overlay(Theme.hairline)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(column < rows[row].count ? rows[row][column] : "")
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(MarkdownText.inline(text))
            .font(.system(size: fontSize - 0.5, weight: weight))
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?
    var isStreaming = false
    @State private var didCopy = false

    var body: some View {
        let codeLanguage = Self.language(named: language)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                if isStreaming {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(didCopy ? Theme.successText : Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Copy this code")
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.04))
            ScrollView(.horizontal) {
                Text(Self.highlighted(code, language: codeLanguage))
                    .font(CodeStyle.codeFont)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeStyle.background, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    static let highlightLineLimit = 2000

    static func highlighted(_ code: String, language: CodeLanguage) -> AttributedString {
        let lines = code.components(separatedBy: "\n")
        guard language != .plain, lines.count <= highlightLineLimit else {
            var plain = AttributedString(code)
            plain.foregroundColor = CodeStyle.color(.plain)
            return plain
        }
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += CodeStyle.highlighted(line, language: language)
        }
        return result
    }

    static func language(named name: String?) -> CodeLanguage {
        guard let name = name?.lowercased(), !name.isEmpty else { return .plain }
        if let exact = CodeLanguage(rawValue: name) { return exact }
        switch name {
        case "console", "terminal", "sh-session", "shellscript": return .shell
        case "golang": return .go
        case "objective-c", "c", "cpp", "c++", "java", "kotlin", "csharp", "cs": return .swift
        default: return CodeLanguage(path: "file.\(name)")
        }
    }
}

struct StreamingCaret: View {
    var fontSize: CGFloat = 13.5
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(width: fontSize * 0.5, height: fontSize * 1.1)
            .opacity(isVisible ? 1 : 0.2)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isVisible)
            .onAppear { isVisible = false }
            .accessibilityLabel("Still writing")
    }
}
