import SaturnCore
import SaturnUI
import SwiftUI

struct TranscriptToolRow: View {
    let tool: ToolActivity
    let root: String?

    var body: some View {
        switch ToolKind(name: tool.name) {
        case .shell: ShellToolRow(tool: tool)
        case .read, .search: FileToolRow(tool: tool, root: root)
        case .edit: EditToolRow(tool: tool, root: root)
        case .subagent: SubagentCard(tool: tool, root: root)
        case .todo: TodoToolRow(tool: tool)
        default: GenericToolRow(tool: tool, root: root)
        }
    }
}

struct ToolCard<Header: View, Detail: View>: View {
    let accessibilityLabel: String
    var isExpandable = true
    @Binding var isExpanded: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                header
                if isExpandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(.rect)
            .onTapGesture { if isExpandable { withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() } } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpandable ? (isExpanded ? "Expanded" : "Collapsed") : "")
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { if isExpandable { isExpanded.toggle() } }
            detail
        }
        .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 10, style: .continuous))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }
}

struct ToolName: View {
    let name: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).accessibilityHidden(true)
            }
            Text(name).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(Theme.link)
        .frame(minWidth: 44, alignment: .leading)
        .fixedSize()
    }
}

struct ToolStatus: View {
    let tool: ToolActivity
    var successLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            if !tool.isFinished {
                if let start = tool.startedAt { ElapsedLabel(start: start) }
                ProgressView().controlSize(.mini)
            } else if tool.isError {
                Text(Self.failureLabel(tool))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            } else {
                if let start = tool.startedAt, let end = tool.finishedAt { ElapsedLabel(start: start, end: end) }
                if let successLabel {
                    Text(successLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.successText)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.successText)
                        .accessibilityLabel("Done")
                }
            }
        }
        .fixedSize()
    }

    static func failureLabel(_ tool: ToolActivity) -> String {
        let result = tool.result ?? ""
        if result.isEmpty || result.contains("doesn't want to proceed") { return "Cancelled" }
        if result.contains("denied") { return "Denied" }
        if let code = ToolResultSummary.exitCode(of: tool), ToolKind(name: tool.name) == .shell { return "exit \(code)" }
        return "Error"
    }
}

struct ToolOutput: View {
    let text: String
    var isError = false
    var maxHeight: CGFloat = 260

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isError ? Theme.danger : Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.opacity(0.2))
    }
}

private struct ShellToolRow: View {
    let tool: ToolActivity
    @State private var isExpanded = false

    var body: some View {
        let command = tool.input["command"]?.string ?? ""
        let description = tool.input["description"]?.string
        let output = ToolResultSummary.shellOutput(of: tool)
        ToolCard(accessibilityLabel: "Bash \(description ?? command)", isExpandable: !output.isEmpty, isExpanded: $isExpanded) {
            ToolName(name: tool.name, symbol: "terminal")
            Text(description ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ToolStatus(tool: tool, successLabel: tool.isFinished && !tool.isError ? "ok" : nil)
        } detail: {
            Text("\(Text("$ ").foregroundStyle(Theme.tertiaryText))\(command)")
                .foregroundStyle(Theme.primaryText)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CodeStyle.background.opacity(0.8))
            if isExpanded, !output.isEmpty {
                ToolOutput(text: output, isError: tool.isError)
            }
        }
    }
}

private struct FileToolRow: View {
    let tool: ToolActivity
    let root: String?
    @State private var isExpanded = false

    var body: some View {
        let paths = ToolResultSummary.paths(in: tool)
        let showsPaths = !paths.isEmpty && tool.input["output_mode"]?.string != "content"
        let result = tool.result ?? ""
        ToolCard(accessibilityLabel: "\(tool.name) \(tool.target(relativeTo: root))", isExpandable: !result.isEmpty, isExpanded: $isExpanded) {
            ToolName(name: tool.name, symbol: ToolKind(name: tool.name) == .read ? "doc.text" : "magnifyingglass")
            target
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count = ToolResultSummary.countLabel(for: tool) {
                Text(count).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).fixedSize()
            }
            ToolStatus(tool: tool)
        } detail: {
            if isExpanded, !result.isEmpty {
                if showsPaths {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(paths.prefix(Self.pathLimit), id: \.self) { path in
                            CodeFileLink(path: path, fontSize: 11.5)
                        }
                        if paths.count > Self.pathLimit {
                            Text("\(paths.count - Self.pathLimit) more").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.black.opacity(0.2))
                } else {
                    ToolOutput(text: result, isError: tool.isError)
                }
            }
        }
    }

    static let pathLimit = 60

    @ViewBuilder
    private var target: some View {
        if let path = tool.filePath {
            CodeFileLink(path: path)
        } else {
            HStack(spacing: 6) {
                Text(tool.input["pattern"]?.string ?? tool.target(relativeTo: root))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let scope = tool.input["path"]?.string {
                    Text("in \(CodeFileLocator.displayPath(scope, root: root))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct EditToolRow: View {
    let tool: ToolActivity
    let root: String?
    @State private var isExpanded = false

    var body: some View {
        let diff = tool.diff
        let result = tool.result ?? ""
        ToolCard(accessibilityLabel: "\(tool.name) \(tool.target(relativeTo: root))", isExpandable: !result.isEmpty, isExpanded: $isExpanded) {
            ToolName(name: tool.name, symbol: "pencil")
            Group {
                if let path = tool.filePath {
                    CodeFileLink(path: path)
                } else {
                    Text(tool.target(relativeTo: root)).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolStatus(tool: tool)
        } detail: {
            if let diff, !tool.isError {
                DiffBlock(lines: diff)
            }
            if isExpanded, !result.isEmpty {
                ToolOutput(text: result, isError: tool.isError)
            }
        }
    }
}

struct SubagentCard: View {
    let tool: ToolActivity
    let root: String?
    var children: [TranscriptItem] = []
    @State private var isExpanded = false

    var body: some View {
        let description = tool.input["description"]?.string ?? "Subagent"
        let prompt = tool.input["prompt"]?.string ?? ""
        let type = tool.input["subagent_type"]?.string
        ToolCard(accessibilityLabel: "Subagent \(description)", isExpanded: $isExpanded) {
            ToolName(name: tool.name, symbol: "person.2")
            HStack(spacing: 6) {
                Text(description).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if let type {
                    Text(type)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.fillRaised, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !children.isEmpty {
                Text(Self.callCount(children))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
            }
            ToolStatus(tool: tool)
        } detail: {
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if !prompt.isEmpty {
                        section("Prompt") { MarkdownText(text: prompt, fontSize: 12.5).foregroundStyle(Theme.secondaryText) }
                    }
                    if !children.isEmpty {
                        section("Tool calls") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(children) { child in
                                    AnyView(TranscriptItemView(item: child, root: root))
                                }
                            }
                        }
                    }
                    if let result = tool.result, !result.isEmpty {
                        section(tool.isError ? "Error" : "Result") {
                            MarkdownText(text: result, fontSize: 12.5).foregroundStyle(tool.isError ? Theme.danger : Theme.primaryText)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.12))
                .overlay(alignment: .leading) { Rectangle().fill(Theme.link.opacity(0.4)).frame(width: 2) }
            }
        }
    }

    static func callCount(_ items: [TranscriptItem]) -> String {
        let count = toolCount(items)
        return "\(count) tool call\(count == 1 ? "" : "s")"
    }

    static func toolCount(_ items: [TranscriptItem]) -> Int {
        items.reduce(0) { total, item in
            switch item {
            case .entry: total + 1
            case .group(let group): total + group.tools.count
            case .subagent(_, let nested): total + 1 + toolCount(nested)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            content()
        }
    }
}

private struct TodoToolRow: View {
    let tool: ToolActivity

    var body: some View {
        let todos = TodoItem.parse(tool.input)
        let done = todos.filter { $0.status == .completed }.count
        HStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).accessibilityHidden(true)
            Text("Updated the todo list · \(done) of \(todos.count) done")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct GenericToolRow: View {
    let tool: ToolActivity
    let root: String?
    @State private var isExpanded = false

    var body: some View {
        let result = tool.result ?? ""
        ToolCard(accessibilityLabel: "\(tool.name) \(tool.target(relativeTo: root))", isExpandable: !result.isEmpty, isExpanded: $isExpanded) {
            ToolName(name: tool.name)
            Text(tool.target(relativeTo: root))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ToolStatus(tool: tool)
        } detail: {
            if isExpanded, !result.isEmpty {
                ToolOutput(text: result, isError: tool.isError)
            }
        }
    }
}

struct ToolGroupRow: View {
    let group: ToolGroup
    let root: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(group.kind)).font(.system(size: 11)).foregroundStyle(Theme.link).accessibilityHidden(true)
                    Text(group.summary).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    if group.failureCount > 0 {
                        Text("\(group.failureCount) failed").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.danger)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 24)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.tools, id: \.id) { tool in
                        TranscriptToolRow(tool: tool, root: root)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    static func symbol(_ kind: ToolKind) -> String {
        switch kind {
        case .shell: "terminal"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .edit: "pencil"
        case .webFetch, .webSearch: "globe"
        case .subagent: "person.2"
        case .todo: "checklist"
        case .other: "wrench.and.screwdriver"
        }
    }
}

struct DiffBlock: View {
    let lines: [DiffLine]
    var maximumLines = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(maximumLines).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) {
                    Text(Self.marker(line.kind)).frame(width: 10, alignment: .center)
                    Text(line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Self.color(line.kind))
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .background(Self.background(line.kind))
            }
            if lines.count > maximumLines {
                Text("\(lines.count - maximumLines) more lines")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    static func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Theme.successText
        case .removed: Color(hex: 0xFF8A80)
        case .context: Theme.secondaryText
        }
    }

    static func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Theme.success.opacity(0.1)
        case .removed: Theme.danger.opacity(0.1)
        case .context: .clear
        }
    }
}
