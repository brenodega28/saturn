import Foundation
import Observation

enum WorkbenchPane: String, Codable, CaseIterable {
    case navigator
    case inspector
    case bottom
}

enum NavigatorScope: String, Codable {
    case project
    case all
}

@MainActor
@Observable
final class WorkbenchState {
    struct Snapshot: Codable {
        var tabs: [EditorItem] = []
        var active: EditorItem?
        var secondary: EditorItem?
        var isSplit = false
        var hidden: Set<WorkbenchPane> = []
        var navigatorWidth: Double = 280
        var inspectorWidth: Double = 300
        var bottomHeight: Double = 250
        var navigatorTab = NavigatorTabID.workspace
        var navigatorScope = NavigatorScope.project
        var bottomTab: String?
        var inspectorTabs: [String: String] = [:]
        var isToolbarHidden = false
    }

    static let maximumTabs = 10
    static let historyLimit = 50

    var tabs: [EditorItem] = []
    var active: EditorItem?
    var secondary: EditorItem?
    var isSplit = false
    var hidden: Set<WorkbenchPane> = []
    var navigatorWidth: Double = 280
    var inspectorWidth: Double = 300
    var bottomHeight: Double = 250
    var navigatorTab = NavigatorTabID.workspace
    var navigatorScope = NavigatorScope.project
    var bottomTab: String?
    var inspectorTabs: [String: String] = [:]
    var isToolbarHidden = false
    private(set) var back: [EditorItem] = []
    private(set) var forward: [EditorItem] = []

    init(snapshot: Snapshot = Snapshot()) {
        restore(snapshot)
    }

    var snapshot: Snapshot {
        Snapshot(
            tabs: tabs, active: active, secondary: secondary, isSplit: isSplit, hidden: hidden,
            navigatorWidth: navigatorWidth, inspectorWidth: inspectorWidth, bottomHeight: bottomHeight,
            navigatorTab: navigatorTab, navigatorScope: navigatorScope, bottomTab: bottomTab,
            inspectorTabs: inspectorTabs, isToolbarHidden: isToolbarHidden
        )
    }

    func restore(_ snapshot: Snapshot) {
        tabs = snapshot.tabs
        active = snapshot.active.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
        secondary = snapshot.secondary
        isSplit = snapshot.isSplit
        hidden = snapshot.hidden
        navigatorWidth = snapshot.navigatorWidth
        inspectorWidth = snapshot.inspectorWidth
        bottomHeight = snapshot.bottomHeight
        navigatorTab = snapshot.navigatorTab
        navigatorScope = snapshot.navigatorScope
        bottomTab = snapshot.bottomTab
        inspectorTabs = snapshot.inspectorTabs
        isToolbarHidden = snapshot.isToolbarHidden
    }

    func isShowing(_ pane: WorkbenchPane) -> Bool {
        !hidden.contains(pane)
    }

    func toggle(_ pane: WorkbenchPane) {
        if hidden.contains(pane) { hidden.remove(pane) } else { hidden.insert(pane) }
    }

    func show(_ pane: WorkbenchPane) {
        hidden.remove(pane)
    }

    func open(_ item: EditorItem, recordingHistory: Bool = true) {
        guard item != active else { return }
        if recordingHistory, let active {
            back.append(active)
            if back.count > Self.historyLimit { back.removeFirst() }
            forward = []
        }
        if !tabs.contains(item) {
            if let active, let index = tabs.firstIndex(of: active) {
                tabs.insert(item, at: index + 1)
            } else {
                tabs.append(item)
            }
            trimTabs(keeping: item)
        }
        active = item
    }

    func openInNewTab(_ item: EditorItem) {
        open(item)
    }

    func close(_ item: EditorItem) {
        guard let index = tabs.firstIndex(of: item) else { return }
        tabs.remove(at: index)
        back.removeAll { $0 == item }
        forward.removeAll { $0 == item }
        if secondary == item { secondary = nil }
        if active == item {
            active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
    }

    func closeOthers(than item: EditorItem) {
        tabs = tabs.filter { $0 == item }
        active = item
        back = []
        forward = []
    }

    func remove(where shouldRemove: (EditorItem) -> Bool) {
        for item in tabs where shouldRemove(item) { close(item) }
        back.removeAll(where: shouldRemove)
        forward.removeAll(where: shouldRemove)
        if let secondary, shouldRemove(secondary) { self.secondary = nil }
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func goBack() {
        guard let previous = back.popLast() else { return }
        if let active { forward.append(active) }
        open(previous, recordingHistory: false)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        if let active { back.append(active) }
        open(next, recordingHistory: false)
    }

    func toggleSplit() {
        isSplit.toggle()
        if isSplit, secondary == nil {
            secondary = tabs.first { $0 != active } ?? active
        }
    }

    func selectNextTab(offset: Int) {
        guard let active, let index = tabs.firstIndex(of: active), !tabs.isEmpty else { return }
        open(tabs[(index + offset + tabs.count) % tabs.count])
    }

    private func trimTabs(keeping item: EditorItem) {
        while tabs.count > Self.maximumTabs, let oldest = tabs.first(where: { $0 != item && $0 != active && $0 != secondary }) {
            tabs.removeAll { $0 == oldest }
        }
    }
}
