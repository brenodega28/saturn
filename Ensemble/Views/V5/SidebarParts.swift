import EnsembleCore
import EnsembleUI
import SwiftUI

struct AddProjectButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Open Folder…") { model.isOpenPanelPresented = true }
            Button("Open SSH Folder…") { model.isRemoteFolderPresented = true }
            Button("Clone Repository…") { model.isClonePresented = true }
            Divider()
            Button("New Project…") { model.newProject() }
        } label: {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add project")
        .accessibilityLabel("Add project")
    }
}

struct NewChatPicker: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let matches = NewChatFilter.match(model.allOpenProjects, name: \.project.name, filter: filter)
        VStack(alignment: .leading, spacing: 6) {
            Text("New chat in…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
            TextField("Filter projects", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Tokens.fill, in: .rect(cornerRadius: 8, style: .continuous))
                .focused($isFocused)
                .onSubmit { pick(matches) }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(matches.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onChange(of: filter) { highlighted = 0 }
            if matches.isEmpty {
                Text("No project matches “\(filter)”. Check the spelling, or add it as a new project.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                Button { start(match) } label: {
                    HStack(spacing: 10) {
                        ProjectTile(project: match.project, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.project.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Tokens.text)
                            Text(match.project.isRemote ? match.project.location : (match.project.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11.5)).foregroundStyle(Tokens.text2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        MachineLabel(workspace: match.workspace)
                        if index == highlighted { Text("⏎").font(.system(size: 11)).foregroundStyle(Tokens.text3) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 42)
                    .background(index == highlighted ? Tokens.selection : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Tokens.hair)
            Button("Add project…") {
                model.isNewChatPickerShown = false
                model.isOpenPanelPresented = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Tokens.link)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }

    private func pick(_ matches: [(workspace: DaemonWorkspace, project: Project)]) {
        guard matches.indices.contains(highlighted) else { return }
        start(matches[highlighted])
    }

    private func start(_ match: (workspace: DaemonWorkspace, project: Project)) {
        model.isNewChatPickerShown = false
        match.workspace.startNewChat(in: match.project)
    }
}

enum NewChatFilter {
    static func match<Item>(_ items: [Item], name: (Item) -> String, filter: String) -> [Item] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        let prefix = items.filter { name($0).lowercased().hasPrefix(needle) }
        let other = items.filter { !name($0).lowercased().hasPrefix(needle) && name($0).lowercased().contains(needle) }
        return prefix + other
    }
}

struct MachineLabel: View {
    let workspace: DaemonWorkspace
    var size: CGFloat = 11
    var showsLocal = false

    var body: some View {
        if workspace.isRemote || showsLocal {
            HStack(spacing: 4) {
                Image(systemName: workspace.systemImage).font(.system(size: size - 1.5))
                Text(workspace.displayName).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: size))
            .foregroundStyle(Tokens.text2)
            .help("On \(workspace.displayName)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("On \(workspace.displayName)")
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showsBudget = false

    var body: some View {
        let spent = model.weeklySpend
        let limit = model.globalWeeklyBudget
        let ratio = limit.map { $0 > 0 ? spent / $0 : 0 } ?? 0
        HStack(spacing: 4) {
            footerButton("Usage", symbol: "chart.bar") { model.open(.usage) }
            footerButton("Settings (⌘,)", symbol: "gearshape") { openSettings() }
            Spacer()
            Button { showsBudget.toggle() } label: {
                HStack(spacing: 5) {
                    if ratio >= 0.8 { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)) }
                    Text(BudgetLabel.text(spent: spent, limit: limit))
                        .font(Tokens.mono(11.5))
                }
                .foregroundStyle(ratio >= 1 ? Tokens.stuck : ratio >= 0.8 ? Tokens.review : Tokens.text2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Spend this week")
            .popover(isPresented: $showsBudget, arrowEdge: .top) { BudgetPopover(spent: spent, limit: limit) }
        }
        .padding(.horizontal, 4)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.text2)
                .frame(width: 34, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

enum BudgetLabel {
    static func text(spent: Double, limit: Double?) -> String {
        let spentText = "$\(Int(spent.rounded()))"
        guard let limit, limit > 0 else { return "\(spentText) wk" }
        return spent > limit ? "\(spentText) / \(Int(limit)) · over" : "\(spentText) / \(Int(limit)) wk"
    }
}

private struct BudgetPopover: View {
    @Environment(AppModel.self) private var model
    let spent: Double
    let limit: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spend").font(.system(size: 13, weight: .semibold))
            meter("This week", spent: spent, limit: limit)
            meter("This month", spent: model.monthlySpend, limit: model.globalMonthlyBudget)
            if let limit, spent > limit {
                Text("Over by $\(Int((spent - limit).rounded())). New workers wait until you raise the limit or the week resets.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.stuck).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Usage →") { model.open(.usage) }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.link)
                .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(width: 280)
    }

    private func meter(_ title: String, spent: Double, limit: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(Tokens.text2)
                Spacer()
                Text(limit.map { String(format: "$%.0f / $%.0f", spent, $0) } ?? String(format: "$%.0f", spent)).font(Tokens.mono(11.5))
            }
            .font(.system(size: 12))
            ProgressView(value: min(spent, limit ?? spent), total: max(limit ?? spent, 1))
                .tint(limit.map { spent > $0 ? Tokens.stuck : Tokens.text2 } ?? Tokens.text2)
        }
    }
}
