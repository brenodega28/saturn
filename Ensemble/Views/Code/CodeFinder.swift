import EnsembleCore
import EnsembleUI
import SwiftUI

struct CodeFinder: View {
    @Bindable var browser: CodeBrowser
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        let results = browser.finderResults
        let selected = results.indices.contains(browser.finderSelection) ? results[browser.finderSelection] : nil
        ZStack(alignment: .top) {
            Tokens.scrim
                .onTapGesture { browser.isFinderPresented = false }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                header(count: results.count)
                Divider().overlay(Tokens.hair)
                HStack(spacing: 0) {
                    resultList(results)
                        .frame(minWidth: 260, idealWidth: 400, maxWidth: 400)
                    Divider().overlay(Tokens.hair)
                    preview(selected)
                }
                .frame(height: 460)
                Divider().overlay(Tokens.hair)
                footer
            }
            .frame(maxWidth: 1040)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 22, style: .continuous))
            .background(Tokens.menu, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Tokens.hair2))
            .shadow(color: .black.opacity(0.6), radius: 50, y: 40)
            .padding(EdgeInsets(top: 40, leading: 24, bottom: 24, trailing: 24))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Go to file")
            .accessibilityAddTraits(.isModal)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isQueryFocused = true
        }
        .onExitCommand { browser.isFinderPresented = false }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(CodeFinderMode.allCases) { mode in
                    let isOn = browser.finderMode == mode
                    Button {
                        browser.finderMode = mode
                        browser.modeChanged()
                        isQueryFocused = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(mode.title).fontWeight(.semibold)
                            Text(mode.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(isOn ? .white : Theme.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(isOn ? Tokens.fill2 : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.25), in: Capsule())
            .fixedSize()
            HStack(spacing: 10) {
                Text("›").font(.system(size: 16, design: .monospaced)).foregroundStyle(Theme.accent).accessibilityHidden(true)
                TextField("Search", text: $browser.finderQuery, prompt: Text(browser.finderMode.placeholder))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, design: .monospaced))
                    .focused($isQueryFocused)
                    .onChange(of: browser.finderQuery) { browser.queryChanged() }
                    .onSubmit { browser.openSelectedResult() }
                    .onKeyPress(.downArrow) { browser.moveFinderSelection(1); return .handled }
                    .onKeyPress(.upArrow) { browser.moveFinderSelection(-1); return .handled }
                    .onKeyPress(.escape) { browser.isFinderPresented = false; return .handled }
            }
            Text(count == CodeBrowser.resultLimit ? "\(count)+" : "\(count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize()
                .help("Results")
            Button { browser.isFinderPresented = false } label: {
                Text("esc")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Tokens.fill2, in: .rect(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func resultList(_ results: [CodeFinderResult]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        let isSelected = index == browser.finderSelection
                        Button { browser.open(result.path, line: result.line) } label: {
                            HStack(spacing: 10) {
                                FileBadge(path: result.path)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(CodeStyle.marked(result.title, matches: result.titleMatches, base: .white, size: 12.5))
                                        .lineLimit(1)
                                    Text(CodeStyle.marked(result.subtitle, matches: result.subtitleMatches, base: Theme.tertiaryText, size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: 4)
                                if let change = browser.change(for: result.path), browser.finderMode == .files {
                                    Text(change.status.mark)
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(CodeStyle.changeColor(change.status))
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 40)
                            .background(isSelected ? Theme.accent.opacity(0.3) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { browser.finderSelection = index } }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    if results.isEmpty {
                        Text(emptyMessage)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .onChange(of: browser.finderSelection) {
                if results.indices.contains(browser.finderSelection) { proxy.scrollTo(results[browser.finderSelection].id) }
            }
        }
    }

    private var emptyMessage: String {
        if browser.finderMode == .text, browser.finderQuery.trimmingCharacters(in: .whitespaces).count < 2 {
            return "Type at least two characters."
        }
        return "No matches. Try fewer letters."
    }

    @ViewBuilder
    private func preview(_ result: CodeFinderResult?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result {
                let lines = browser.lines(result.path)
                let language = CodeLanguage(path: result.path)
                let start = max(0, result.line - 8)
                Text(result.line > 1 ? "\(result.path):\(result.line)" : result.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider().overlay(Tokens.hair)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.dropFirst(start).prefix(40).enumerated()), id: \.offset) { offset, text in
                            let number = start + offset + 1
                            HStack(spacing: 0) {
                                Text("\(number)")
                                    .foregroundStyle(Color.white.opacity(0.35))
                                    .frame(width: 46, alignment: .trailing)
                                    .padding(.trailing, 14)
                                Text(CodeStyle.highlighted(text, language: language)).fixedSize()
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(number == result.line && result.line > 1 ? Theme.accent.opacity(0.16) : .clear)
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.18))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("↑ ↓ choose")
            Text("↵ open")
            Text("esc close")
            Text("Letters can be skipped: \(Text("ordser").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.primaryText)) finds orders/serializers.py")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
