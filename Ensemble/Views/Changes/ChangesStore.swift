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
    var layout: DiffLayout = .unified {
        didSet { if layout != oldValue { lineSelection = nil } }
    }
    private(set) var lineSelection: LineSelection?
    private(set) var changeSet: RunChangeSet?
    private(set) var loadedRunID: Int64?
    private(set) var isLoading = false
    var pins: [Pin] = []
    var policy = ReviewPolicy()
    var labels: [String] = []
    var evidence: [Evidence] = []
    var gates: GateReport?
    var viewed: Set<String> = []
    var collapsed: Set<String> = []
    var expandedGenerated: Set<String> = []
    var fullyShown: Set<String> = []

    func select(_ run: Run, replacing current: Run) {
        guard run.id != current.id else { return }
        select(runID: run.id)
    }

    func select(runID: Int64?) {
        selectedRunID = runID
        agentFilter = nil
        changeSet = nil
        loadedRunID = nil
        pins = []
        viewed = []
        collapsed = []
        expandedGenerated = []
        fullyShown = []
        lineSelection = nil
    }

    func selectLine(_ target: LineTarget, in entryID: String, extending: Bool) {
        lineSelection = LineSelection.next(after: lineSelection, clicking: target, in: entryID, extending: extending)
    }

    func clearLineSelection() {
        lineSelection = nil
    }

    func lineSelection(for entryID: String) -> LineSelection? {
        lineSelection?.entryID == entryID ? lineSelection : nil
    }

    func selectedRun(from runs: [Run]) -> Run? {
        runs.first { $0.id == selectedRunID } ?? runs.first
    }

    func load(_ run: Run, in project: Project, workspace model: DaemonWorkspace) async {
        isLoading = true
        defer { isLoading = false }
        let loaded = await model.loadChanges(for: run, in: project)
        guard selectedRunID == run.id || selectedRunID == nil else { return }
        changeSet = loaded
        loadedRunID = run.id
        viewed = model.viewedPaths(in: run, current: loaded?.paths ?? [])
        policy = model.config(for: project).review
        labels = (try? model.database.task(id: run.taskId))??.labels ?? []
        if let id = run.id {
            evidence = (try? model.database.evidence(runId: id)) ?? []
            gates = model.latestGateReport(in: run)
        }
        for path in allPaths where tier(of: path.path) == .low && !viewed.contains(path.path) {
            collapsed.insert(path.path)
        }
    }

    var allPaths: [ChangedPath] {
        (changeSet?.paths ?? []).sorted { lhs, rhs in
            let left = tier(of: lhs.path), right = tier(of: rhs.path)
            return left == right ? lhs.path < rhs.path : left < right
        }
    }

    func tier(of path: String) -> RiskTier {
        policy.riskTiers.tier(of: path, labels: labels)
    }

    var unviewedCoreFiles: [ChangedPath] {
        allPaths.filter { tier(of: $0.path) == .core && !viewed.contains($0.path) }
    }

    var reviewPins: [Pin] {
        pins.filter { $0.byUser || !policy.reviewer.hides(confidence: $0.confidence, category: $0.category) }
    }

    var hiddenPinCount: Int { pins.count - reviewPins.count }

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

    var openPins: [Pin] { reviewPins.filter { $0.status == .open } }
    var changeRequests: [Pin] { reviewPins.filter { $0.status == .changeRequested } }

    func pins(for path: ChangedPath) -> [Pin] {
        reviewPins.filter { Self.pin($0, belongsTo: path.path) }
    }

    var pinsOutsideChanges: [Pin] {
        let paths = allPaths
        return reviewPins.filter { pin in !paths.contains { Self.pin(pin, belongsTo: $0.path) } }
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
