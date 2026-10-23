import EnsembleCore
import Foundation
import Observation

enum DiffLayout: String, CaseIterable, Identifiable {
    case unified
    case split

    var id: Self { self }

    var title: String {
        switch self {
        case .unified: "Unified"
        case .split: "Split"
        }
    }
}

@MainActor
@Observable
final class ChangesStore {
    var selectedRunID: Int64?
    var agentFilter: Int64?
    var layout: DiffLayout = .unified
    private(set) var changeSet: RunChangeSet?
    private(set) var loadedRunID: Int64?
    private(set) var isLoading = false
    var pins: [Pin] = []
    var viewed: Set<String> = []
    var collapsed: Set<String> = []
    var expandedGenerated: Set<String> = []
    var fullyShown: Set<String> = []

    func select(_ run: Run, replacing current: Run) {
        guard run.id != current.id else { return }
        selectedRunID = run.id
        agentFilter = nil
        changeSet = nil
        loadedRunID = nil
        pins = []
        viewed = []
        collapsed = []
        expandedGenerated = []
        fullyShown = []
    }

    func selectedRun(from runs: [Run]) -> Run? {
        runs.first { $0.id == selectedRunID } ?? runs.first
    }

    func load(_ run: Run, in project: Project, model: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        let loaded = await model.loadChanges(for: run, in: project)
        guard selectedRunID == run.id || selectedRunID == nil else { return }
        changeSet = loaded
        loadedRunID = run.id
        viewed = model.viewedPaths(in: run, current: loaded?.paths ?? [])
    }

    var allPaths: [ChangedPath] { changeSet?.paths ?? [] }

    var visiblePaths: [ChangedPath] {
        guard let agentFilter else { return allPaths }
        return allPaths.compactMap { path in
            let diffs = path.diffs.filter { $0.agentId == agentFilter }
            guard !diffs.isEmpty else { return nil }
            var filtered = path
            filtered.diffs = diffs
            return filtered
        }
    }

    var codingAgents: [Agent] { changeSet?.branches.map(\.agent) ?? [] }

    var openPins: [Pin] { pins.filter { $0.status == .open } }
    var changeRequests: [Pin] { pins.filter { $0.status == .changeRequested } }

    func pins(for path: ChangedPath) -> [Pin] {
        pins.filter { Self.pin($0, belongsTo: path.path) }
    }

    var pinsOutsideChanges: [Pin] {
        let paths = allPaths
        return pins.filter { pin in !paths.contains { Self.pin(pin, belongsTo: $0.path) } }
    }

    static func pin(_ pin: Pin, belongsTo path: String) -> Bool {
        let file = pin.file.hasPrefix("./") ? String(pin.file.dropFirst(2)) : pin.file
        return file == path || path.hasSuffix("/" + file)
    }

    func isExpanded(_ path: ChangedPath) -> Bool {
        if path.isGenerated && !expandedGenerated.contains(path.path) { return false }
        return !viewed.contains(path.path) && !collapsed.contains(path.path)
    }

    func toggleExpanded(_ path: ChangedPath) {
        if isExpanded(path) {
            collapsed.insert(path.path)
            expandedGenerated.remove(path.path)
        } else {
            collapsed.remove(path.path)
            viewed.remove(path.path)
            if path.isGenerated { expandedGenerated.insert(path.path) }
        }
    }

    func reveal(_ path: String) {
        collapsed.remove(path)
        if allPaths.first(where: { $0.path == path })?.isGenerated == true { expandedGenerated.insert(path) }
    }
}
