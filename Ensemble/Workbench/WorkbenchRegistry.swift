import SwiftUI

enum NavigatorTabID {
    static let workspace = "workspace"
}

enum InspectorSubject: Hashable {
    case agent(project: Int64, agent: Int64)
    case file(project: Int64, path: String)
    case run(project: Int64, run: Int64)
    case step(project: Int64, workflow: String, step: String)

    enum Kind: String {
        case agent
        case file
        case run
        case step
    }

    var kind: Kind {
        switch self {
        case .agent: .agent
        case .file: .file
        case .run: .run
        case .step: .step
        }
    }

    var project: Int64 {
        switch self {
        case .agent(let project, _), .file(let project, _), .run(let project, _), .step(let project, _, _): project
        }
    }
}

struct NavigatorTabSpec: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let order: Int
    var showsScope = false
    var badge: @MainActor (AppModel) -> Int? = { _ in nil }
    let content: @MainActor () -> AnyView
}

struct InspectorTabSpec: Identifiable {
    let id: String
    let title: String
    let subject: InspectorSubject.Kind
    let order: Int
    let content: @MainActor (InspectorSubject) -> AnyView
}

struct BottomPanelTabSpec: Identifiable {
    let id: String
    let title: String
    let order: Int
    var badge: @MainActor (AppModel) -> Int? = { _ in nil }
    let content: @MainActor () -> AnyView
}

struct JumpOption: Identifiable {
    let title: String
    var isCurrent = false
    let item: EditorItem

    var id: String { item.id + title }
}

struct JumpSegment: Identifiable {
    let title: String
    var options: [JumpOption] = []

    var id: String { title }
}

struct EditorKindSpec: Identifiable {
    let id: String
    let title: @MainActor (EditorItem, AppModel) -> String
    let systemImage: @MainActor (EditorItem) -> String
    var jumpBar: @MainActor (EditorItem, AppModel) -> [JumpSegment] = { _, _ in [] }
    var inspectorSubject: @MainActor (EditorItem, AppModel) -> InspectorSubject? = { _, _ in nil }
    var accessory: (@MainActor (EditorItem) -> AnyView)?
    var isAvailable: @MainActor (EditorItem, AppModel) -> Bool = { _, _ in true }
    let content: @MainActor (EditorItem) -> AnyView
}

enum ToolbarPlacement {
    case leading
    case center
    case trailing
}

struct ToolbarItemSpec: Identifiable {
    let id: String
    let placement: ToolbarPlacement
    let order: Int
    let content: @MainActor () -> AnyView
}

enum StatusPlacement {
    case leading
    case trailing
}

struct StatusItemSpec: Identifiable {
    let id: String
    let placement: StatusPlacement
    let order: Int
    let content: @MainActor () -> AnyView
}

struct ActivityEntry: Identifiable {
    let id: String
    let title: String
    var detail = ""
    var trailing = ""
    var progress: Double?
}

struct ActivitySourceSpec: Identifiable {
    let id: String
    let title: String
    let order: Int
    let entries: @MainActor (AppModel) -> [ActivityEntry]
}

struct CommandContext {
    let model: AppModel
    let workbench: WorkbenchState?
    let openWindow: OpenWindowAction?
    var target: CommandTarget?
}

struct WorkbenchCommand: Identifiable {
    let id: String
    let title: String
    let menu: String
    var section = 0
    var order = 0
    var shortcut: KeyboardShortcut?
    var keywords = ""
    var isEnabled: @MainActor (CommandContext) -> Bool = { _ in true }
    var isChecked: (@MainActor (CommandContext) -> Bool)?
    let perform: @MainActor (CommandContext) -> Void
}

@MainActor
final class WorkbenchRegistry {
    static let shared: WorkbenchRegistry = {
        let registry = WorkbenchRegistry()
        registry.registerBuiltIns()
        return registry
    }()

    private(set) var navigatorTabs: [NavigatorTabSpec] = []
    private(set) var inspectorTabs: [InspectorTabSpec] = []
    private(set) var bottomTabs: [BottomPanelTabSpec] = []
    private(set) var editorKinds: [String: EditorKindSpec] = [:]
    private(set) var toolbarItems: [ToolbarItemSpec] = []
    private(set) var statusItems: [StatusItemSpec] = []
    private(set) var activitySources: [ActivitySourceSpec] = []
    private(set) var commands: [WorkbenchCommand] = []

    func register(_ tab: NavigatorTabSpec) {
        navigatorTabs.removeAll { $0.id == tab.id }
        navigatorTabs.append(tab)
        navigatorTabs.sort { $0.order < $1.order }
    }

    func register(_ tab: InspectorTabSpec) {
        inspectorTabs.removeAll { $0.id == tab.id && $0.subject == tab.subject }
        inspectorTabs.append(tab)
        inspectorTabs.sort { $0.order < $1.order }
    }

    func register(_ tab: BottomPanelTabSpec) {
        bottomTabs.removeAll { $0.id == tab.id }
        bottomTabs.append(tab)
        bottomTabs.sort { $0.order < $1.order }
    }

    func register(_ kind: EditorKindSpec) {
        editorKinds[kind.id] = kind
    }

    func register(_ item: ToolbarItemSpec) {
        toolbarItems.removeAll { $0.id == item.id }
        toolbarItems.append(item)
        toolbarItems.sort { $0.order < $1.order }
    }

    func register(_ item: StatusItemSpec) {
        statusItems.removeAll { $0.id == item.id }
        statusItems.append(item)
        statusItems.sort { $0.order < $1.order }
    }

    func register(_ source: ActivitySourceSpec) {
        activitySources.removeAll { $0.id == source.id }
        activitySources.append(source)
        activitySources.sort { $0.order < $1.order }
    }

    func register(_ command: WorkbenchCommand) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    func inspectorTabs(for kind: InspectorSubject.Kind) -> [InspectorTabSpec] {
        inspectorTabs.filter { $0.subject == kind }
    }

    func toolbarItems(_ placement: ToolbarPlacement) -> [ToolbarItemSpec] {
        toolbarItems.filter { $0.placement == placement }
    }

    func statusItems(_ placement: StatusPlacement) -> [StatusItemSpec] {
        statusItems.filter { $0.placement == placement }
    }

    func commands(in menu: String) -> [[WorkbenchCommand]] {
        let matching = commands.filter { $0.menu == menu }
        return Dictionary(grouping: matching, by: \.section)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.order < $1.order } }
    }

    static let menuBar = ["File", "View", "Navigate", "Agent", "Run", "Review", "Workflow", "Window", "Help"]

    func command(_ id: String) -> WorkbenchCommand? {
        commands.first { $0.id == id }
    }

    func editorKind(for item: EditorItem) -> EditorKindSpec? {
        editorKinds[item.kind]
    }
}

extension KeyboardShortcut {
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.displayString
    }
}

extension KeyEquivalent {
    var displayString: String {
        switch self {
        case .return: "↩"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .delete: "⌫"
        case .escape: "⎋"
        case .tab: "⇥"
        case .space: "Space"
        default: String(character).uppercased()
        }
    }
}
