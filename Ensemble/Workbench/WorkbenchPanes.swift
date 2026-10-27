import EnsembleCore
import EnsembleUI
import SwiftUI

struct NavigatorPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let tabs = WorkbenchRegistry.shared.navigatorTabs
        let current = tabs.first { $0.id == state.navigatorTab } ?? tabs.first
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    NavigatorTabButton(tab: tab, index: index, isSelected: tab.id == current?.id) {
                        state.navigatorTab = tab.id
                    }
                    if tab.id != tabs.last?.id { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider().overlay(Theme.hairline)
            if let current {
                if current.id != NavigatorTabID.workspace {
                    NavigatorHeader(tab: current)
                }
                current.content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.sidebarBackground)
    }
}

private struct NavigatorTabButton: View {
    @Environment(AppModel.self) private var model
    let tab: NavigatorTabSpec
    let index: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? Theme.link : Theme.secondaryText)
                .frame(width: 28, height: 26)
                .background(isSelected ? Theme.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let badge = tab.badge(model), badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 3)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Color(hex: 0x3A3A40), in: .capsule)
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "\(tab.title) (⌘\(index + 1))" : tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct NavigatorHeader: View {
    @Environment(WorkbenchState.self) private var state
    let tab: NavigatorTabSpec

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            Text(tab.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
            if tab.showsScope {
                Picker("Scope", selection: $state.navigatorScope) {
                    Text("Project").tag(NavigatorScope.project)
                    Text("All").tag(NavigatorScope.all)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
    }
}

struct InspectorPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let subject = state.active.flatMap { item in
            WorkbenchRegistry.shared.editorKind(for: item)?.inspectorSubject(item, model)
        }
        VStack(spacing: 0) {
            if let subject {
                InspectorContent(subject: subject)
            } else {
                VStack(spacing: 8) {
                    Text("No selection").font(.system(size: 13, weight: .semibold))
                    Text("Select a run, an agent, a file or a workflow step to inspect it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
                .padding(.top, 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.sidebarBackground)
    }
}

private struct InspectorContent: View {
    @Environment(WorkbenchState.self) private var state
    let subject: InspectorSubject

    var body: some View {
        let tabs = WorkbenchRegistry.shared.inspectorTabs(for: subject.kind)
        let selectedID = state.inspectorTabs[subject.kind.rawValue]
        let current = tabs.first { $0.id == selectedID } ?? tabs.first
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(subject.kind.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                if tabs.count > 1 {
                    SegmentedTabs(
                        titles: tabs.map(\.title),
                        selection: tabs.firstIndex { $0.id == current?.id } ?? 0
                    ) { index in
                        state.inspectorTabs[subject.kind.rawValue] = tabs[index].id
                    }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            Divider().overlay(Theme.hairline)
            ScrollView {
                if let current {
                    current.content(subject)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Nothing to inspect yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(12)
                }
            }
        }
    }
}

struct SegmentedTabs: View {
    let titles: [String]
    let selection: Int
    let pick: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button { pick(index) } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(index == selection ? Color.white : Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(index == selection ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

extension InspectorSubject.Kind {
    var title: String {
        switch self {
        case .agent: "Agent"
        case .file: "File"
        case .run: "Run"
        case .step: "Workflow step"
        }
    }
}

struct BottomPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        let tabs = WorkbenchRegistry.shared.bottomTabs
        let current = tabs.first { $0.id == state.bottomTab } ?? tabs.first
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let isSelected = tab.id == current?.id
                    Button { state.bottomTab = tab.id } label: {
                        HStack(spacing: 6) {
                            Text(tab.title)
                            if let badge = tab.badge(model), badge > 0 {
                                Text("\(badge)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Color.white.opacity(0.1), in: .capsule)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if isSelected { Rectangle().fill(Theme.accent).frame(height: 2) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { state.toggle(.bottom) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Hide bottom panel (⇧⌘Y)")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            Divider().overlay(Theme.hairline)
            if let current {
                current.content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("No panels")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: 0x161619))
    }
}

struct StatusBar: View {
    var body: some View {
        let registry = WorkbenchRegistry.shared
        HStack(spacing: 2) {
            ForEach(registry.statusItems(.leading)) { $0.content() }
            Spacer(minLength: 8)
            ForEach(registry.statusItems(.trailing)) { $0.content() }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(hex: 0x141417))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct StatusButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct WorkbenchToolbar: ToolbarContent {
    let isHidden: Bool

    var body: some ToolbarContent {
        let registry = WorkbenchRegistry.shared
        ToolbarItemGroup(placement: .navigation) {
            ForEach(registry.toolbarItems(.leading)) { $0.content() }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                ForEach(registry.toolbarItems(.center)) { $0.content() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(registry.toolbarItems(.trailing)) { $0.content() }
        }
    }
}
