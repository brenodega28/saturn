import EnsembleCore
import EnsembleUI
import SwiftUI

struct CodeReader: View {
    @Environment(AppModel.self) private var model
    let browser: CodeBrowser
    let project: Project
    @State private var sourceModePaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            CodeTabStrip(browser: browser)
            if let path = browser.activePath {
                let lines = browser.lines(path)
                let language = CodeLanguage(path: path)
                let markdownMode = markdownMode(for: path, language: language)
                let symbols = CodeOutline.symbols(lines, language: language)
                let current = symbols.last { $0.line <= browser.focusLine }
                FileBar(browser: browser, path: path, symbol: markdownMode == .rendered ? nil : current, markdownMode: markdownModeBinding(for: path, mode: markdownMode)) {
                    model.setTab(.changes, for: project)
                }
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        switch browser.document(path) {
                        case .text(let lines) where markdownMode == .rendered:
                            MarkdownDocumentView(text: lines.joined(separator: "\n"))
                        case .text(let lines):
                            CodeLines(browser: browser, path: path, lines: lines, language: language) {
                                model.setTab(.changes, for: project)
                            }
                        case .binary:
                            unreadable("Binary file", "Ensemble shows text files only.")
                        case .tooLarge(let bytes):
                            unreadable("File too large", "\(bytes.formatted(.byteCount(style: .file))) is over the \(CodeWorkspace.maxDocumentBytes.formatted(.byteCount(style: .file))) reader limit.")
                        case .missing:
                            unreadable("File not found", "It may have been deleted or moved since the list was loaded.")
                        case .loading:
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if proxy.size.width >= 640, !symbols.isEmpty, markdownMode != .rendered {
                            Divider().overlay(Tokens.hair)
                            CodeOutlineList(browser: browser, symbols: symbols, current: current)
                                .frame(width: 200)
                        }
                    }
                }
                CodeStatusBar(browser: browser, path: path, lineCount: lines.count, language: language)
            } else {
                VStack(spacing: 12) {
                    Text("No file open").font(.system(size: 16, weight: .semibold))
                    Text("Pick one in the explorer, or jump to any file with Go to file.")
                        .foregroundStyle(Theme.secondaryText)
                    Button("Go to file ⌘P") { browser.presentFinder() }
                        .buttonStyle(.primaryPill)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func markdownMode(for path: String, language: CodeLanguage) -> MarkdownReaderMode? {
        guard language == .markdown else { return nil }
        return sourceModePaths.contains(path) ? .source : .rendered
    }

    private func markdownModeBinding(for path: String, mode: MarkdownReaderMode?) -> Binding<MarkdownReaderMode>? {
        guard let mode else { return nil }
        return Binding(get: { mode }, set: { newMode in
            if newMode == .source { sourceModePaths.insert(path) } else { sourceModePaths.remove(path) }
        })
    }

    private func unreadable(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CodeTabStrip: View {
    let browser: CodeBrowser

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(browser.tabs, id: \.self) { path in
                    let isActive = browser.activePath == path
                    HStack(spacing: 4) {
                        Button { browser.activate(path) } label: {
                            HStack(spacing: 7) {
                                FileBadge(path: path, size: 14)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(isActive ? .white : Theme.secondaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxHeight: .infinity)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(path)
                        Button { browser.close(path) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 20, height: 20)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close \((path as NSString).lastPathComponent)")
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .frame(height: 38)
                    .background(isActive ? CodeStyle.background : .clear)
                    .overlay(alignment: .top) {
                        if isActive { Rectangle().fill(Theme.accent).frame(height: 2) }
                    }
                    .overlay(alignment: .trailing) { Rectangle().fill(Tokens.hair).frame(width: 1) }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover)
        .overlay(alignment: .bottom) { Divider().overlay(Tokens.hair) }
    }
}

private struct FileBar: View {
    let browser: CodeBrowser
    let path: String
    let symbol: CodeSymbol?
    let markdownMode: Binding<MarkdownReaderMode>?
    let openChanges: () -> Void

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    let isLast = index == parts.count - 1
                    Text(part)
                        .foregroundStyle(isLast ? .white : Theme.secondaryText)
                        .fontWeight(isLast ? .semibold : .regular)
                    if !isLast || symbol != nil {
                        Text("›").foregroundStyle(Theme.tertiaryText).accessibilityHidden(true)
                    }
                }
                if let symbol {
                    Text(symbol.name).foregroundStyle(CodeStyle.color(.function)).fontWeight(.medium)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .truncationMode(.head)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Path \(path)")
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                actions(compact: false)
                actions(compact: true)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().overlay(Tokens.hair) }
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let markdownMode {
                Picker("Markdown view", selection: markdownMode) {
                    ForEach(MarkdownReaderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show this Markdown file rendered or as source")
            }
            if let change = browser.change(for: path) {
                Button(action: openChanges) {
                    HStack(spacing: 6) {
                        SourceDot(browser: browser)
                        Text(compact
                             ? "+\(change.addedLineCount)"
                             : "\(change.status == .added ? "Added" : "Changed") by \(browser.source?.changeAuthor ?? "you") · +\(change.addedLineCount)")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.successText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.success.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(change.status == .added ? "Added" : "Changed") by \(browser.source?.changeAuthor ?? "you"). Review it in Changes")
            }
            if !compact {
                Text("Read-only")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Tokens.fill, in: Capsule())
            }
            Button { browser.presentFinder() } label: {
                HStack(spacing: 4) {
                    if !compact { Text("Go to file") }
                    Text("⌘P").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Tokens.fill, in: Capsule())
                .overlay(Capsule().strokeBorder(Tokens.hair2))
            }
            .buttonStyle(.plain)
            .help("Go to file")
        }
        .fixedSize()
    }
}

private struct SourceDot: View {
    let browser: CodeBrowser

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(browser.source?.agent == nil ? AnyShapeStyle(Theme.success) : AnyShapeStyle(RoleAppearance(role: browser.source?.role).palette.gradient))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

private struct CodeLines: View {
    let browser: CodeBrowser
    let path: String
    let lines: [String]
    let language: CodeLanguage
    let openChanges: () -> Void

    var body: some View {
        let change = browser.change(for: path)
        let pins = browser.pins[path] ?? []
        let digits = max(3, String(lines.count).count)
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { offset, text in
                        let number = offset + 1
                        let pinned = pins.contains { (min($0.startLine, $0.endLine)...max($0.startLine, $0.endLine)).contains(number) }
                        let changed = change?.contains(line: number) ?? false
                        let focused = number == browser.focusLine
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(pinned ? CodeStyle.pin : changed ? Theme.success : .clear)
                                .frame(width: 4)
                            Text("\(number)")
                                .foregroundStyle(focused ? .white : Color.white.opacity(0.32))
                                .frame(width: CGFloat(digits) * 8 + 28, alignment: .trailing)
                                .padding(.trailing, 16)
                                .onTapGesture { browser.focus(number) }
                            Text(CodeStyle.highlighted(text, language: language))
                                .fixedSize()
                                .textSelection(.enabled)
                                .padding(.trailing, 40)
                        }
                        .font(CodeStyle.codeFont)
                        .frame(height: CodeStyle.lineHeight, alignment: .leading)
                        .frame(minWidth: viewport.size.width, alignment: .leading)
                        .background(focused ? Theme.accent.opacity(0.14) : pinned ? CodeStyle.pin.opacity(0.06) : changed ? Theme.success.opacity(0.05) : .clear)
                        .id(number)
                        ForEach(pins.filter { max($0.startLine, $0.endLine) == number }) { pin in
                            PinBanner(pin: pin, author: browser.source.flatMap { $0.agent == nil ? nil : $0.changeAuthor }, open: openChanges)
                                .frame(width: viewport.size.width, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .onChange(of: browser.scrollRequest, initial: true) {
                let target = browser.focusLine
                Task { @MainActor in
                    proxy.scrollTo(max(1, target - 6), anchor: .top)
                }
            }
        }
        }
    }
}

private struct PinBanner: View {
    let pin: Pin
    let author: String?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(CodeStyle.pin).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.title).font(.system(size: 12.5, weight: .semibold))
                Text("\(author.map { "Pinned by \($0) · " } ?? "")lines \(pin.startLine)–\(pin.endLine)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Review in Changes →", action: open)
                .buttonStyle(.plain)
                .fixedSize()
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFF9A5C))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CodeStyle.pin.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CodeStyle.pin.opacity(0.35)))
        .frame(maxWidth: 700, alignment: .leading)
        .padding(EdgeInsets(top: 4, leading: 56, bottom: 6, trailing: 16))
        .help(pin.explanation)
    }
}

private struct CodeOutlineList: View {
    let browser: CodeBrowser
    let symbols: [CodeSymbol]
    let current: CodeSymbol?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Outline")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(symbols) { symbol in
                    Button { browser.focus(symbol.line) } label: {
                        HStack(spacing: 7) {
                            Text(kindLabel(symbol.kind))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(kindColor(symbol.kind))
                                .frame(width: 14, height: 14)
                                .background(kindColor(symbol.kind).opacity(0.2), in: .rect(cornerRadius: 4, style: .continuous))
                                .accessibilityHidden(true)
                            Text(symbol.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text("\(symbol.line)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.white.opacity(0.4))
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.primaryText.opacity(0.9))
                        .padding(.leading, 8 + CGFloat(symbol.depth) * 12)
                        .padding(.trailing, 8)
                        .frame(height: 26)
                        .background(symbol == current ? Tokens.fill : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(symbol.name), line \(symbol.line)")
                }
            }
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10))
        }
    }

    private func kindLabel(_ kind: CodeSymbol.Kind) -> String {
        switch kind {
        case .type: "C"
        case .function: "ƒ"
        case .heading: "#"
        case .section: "[]"
        }
    }

    private func kindColor(_ kind: CodeSymbol.Kind) -> Color {
        kind == .type ? CodeStyle.color(.type) : kind == .function ? CodeStyle.color(.function) : Theme.secondaryText
    }
}

private struct CodeStatusBar: View {
    let browser: CodeBrowser
    let path: String
    let lineCount: Int
    let language: CodeLanguage

    var body: some View {
        HStack(spacing: 16) {
            Text(language.title)
            Text("\(lineCount) lines")
            Text("Ln \(browser.focusLine)")
            Spacer()
            Text(browser.source?.branch ?? "")
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Tokens.hover)
        .overlay(alignment: .top) { Divider().overlay(Tokens.hair) }
    }
}
