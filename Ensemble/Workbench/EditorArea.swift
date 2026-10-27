import EnsembleCore
import EnsembleUI
import SwiftUI

struct EditorArea: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            EditorTabStrip()
            if let active = state.active {
                JumpBar(item: active)
                if state.isSplit, let secondary = state.secondary, secondary != active, model.isAvailable(secondary) {
                    HStack(spacing: 0) {
                        EditorContent(item: active)
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        VStack(spacing: 0) {
                            SecondaryEditorHeader(item: secondary)
                            EditorContent(item: secondary)
                        }
                    }
                } else {
                    EditorContent(item: active)
                }
            } else {
                EmptyState("No editor open", message: "Pick something in the navigator, or press ⌘K to search runs, agents and files.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: 0x1A1A1E))
    }
}

struct EditorContent: View {
    @Environment(AppModel.self) private var model
    let item: EditorItem

    var body: some View {
        Group {
            if let kind = WorkbenchRegistry.shared.editorKind(for: item), model.isAvailable(item) {
                kind.content(item)
                    .id(item)
            } else {
                EmptyState("Nothing to show", message: "This item was closed or no longer exists.")
            }
        }
        .environment(\.showsScreenHeader, false)
        .environment(\.isInWorkbench, true)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct EditorTabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(state.tabs) { item in
                        EditorTabView(item: item, isActive: item == state.active)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { state.toggleSplit() } label: {
                Image(systemName: "rectangle.split.2x1")
                    .frame(width: 32, height: 36)
                    .background(state.isSplit ? Color.white.opacity(0.08) : .clear)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Split editor (⌃⌘T)")
            .accessibilityLabel("Split editor")
            Button {
                if let active = state.active, let destination = active.detailDestination { openWindow(id: WindowID.detail, value: destination) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .frame(width: 32, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(state.active?.detailDestination == nil)
            .help("Open in new window")
            .accessibilityLabel("Open in new window")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .frame(height: 36)
        .background(Color(hex: 0x151518))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private struct EditorTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let item: EditorItem
    let isActive: Bool
    @State private var isHovered = false

    var body: some View {
        let kind = WorkbenchRegistry.shared.editorKind(for: item)
        let title = model.editorTitle(item)
        HStack(spacing: 2) {
            Button { state.open(item) } label: {
                HStack(spacing: 7) {
                    Image(systemName: kind?.systemImage(item) ?? "doc").font(.system(size: 11))
                    Text(title).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.white : Theme.secondaryText)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button { state.close(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .opacity(isActive || isHovered ? 1 : 0)
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 4))
        .frame(maxWidth: 220, maxHeight: .infinity)
        .background(isActive ? Color(hex: 0x1D1D21) : .clear)
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Tab") { state.close(item) }
            Button("Close Other Tabs") { state.closeOthers(than: item) }
            Divider()
            Button("Open in Split") {
                state.secondary = item
                state.isSplit = true
            }
            if let destination = item.detailDestination {
                Button("Open in New Window") { openWindow(id: WindowID.detail, value: destination) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct JumpBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let item: EditorItem

    var body: some View {
        let kind = WorkbenchRegistry.shared.editorKind(for: item)
        let segments = kind?.jumpBar(item, model) ?? []
        HStack(spacing: 2) {
            Button { state.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 22).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!state.canGoBack)
            .help("Back (⌃⌘←)")
            Button { state.goForward() } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 22).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!state.canGoForward)
            .help("Forward (⌃⌘→)")
            .padding(.trailing, 4)
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").foregroundStyle(Theme.tertiaryText)
                }
                JumpSegmentButton(segment: segment, isLast: index == segments.count - 1)
            }
            Spacer(minLength: 8)
            if let accessory = kind?.accessory {
                accessory(item)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color(hex: 0x1D1D21))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

private struct JumpSegmentButton: View {
    @Environment(WorkbenchState.self) private var state
    let segment: JumpSegment
    let isLast: Bool

    var body: some View {
        if segment.options.isEmpty {
            label
        } else {
            Menu {
                ForEach(segment.options) { option in
                    Toggle(option.title, isOn: Binding(get: { option.isCurrent }, set: { _ in state.open(option.item) }))
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var label: some View {
        Text(segment.title)
            .fontWeight(isLast ? .semibold : .regular)
            .foregroundStyle(isLast ? Color.white : Theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(.rect)
    }
}

private struct SecondaryEditorHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var state
    let item: EditorItem

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(state.tabs) { tab in
                    Toggle(model.editorTitle(tab), isOn: Binding(get: { tab == item }, set: { _ in state.secondary = tab }))
                }
            } label: {
                Text(model.editorTitle(item)).font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Spacer(minLength: 0)
            Button { state.isSplit = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 20).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Close split")
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(hex: 0x1D1D21))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

extension EditorItem {
    var detailDestination: DetailDestination? {
        guard let project else { return nil }
        switch kind {
        case EditorKindID.run: return number.map { .run(project: project, run: $0) }
        case EditorKindID.agent: return number.map { .agent(project: project, agent: $0) }
        case EditorKindID.file: return ref.map { .file(project: project, path: $0) }
        default: return nil
        }
    }
}
