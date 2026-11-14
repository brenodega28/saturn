import EnsembleCore
import Foundation
import Observation

enum CodeFinderMode: String, CaseIterable, Identifiable {
    case files
    case symbols
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .symbols: "Symbols"
        case .text: "Text"
        }
    }

    var key: String {
        switch self {
        case .files: "⌘P"
        case .symbols: "@"
        case .text: "#"
        }
    }

    var placeholder: String {
        switch self {
        case .files: "Part of a path, e.g. ordser"
        case .symbols: "A class or function"
        case .text: "Text in any file"
        }
    }
}

struct CodeFinderResult: Identifiable, Hashable {
    let path: String
    let line: Int
    let title: String
    let titleMatches: [Int]
    let subtitle: String
    let subtitleMatches: [Int]

    var id: String { "\(path):\(line):\(title)" }
}

@MainActor
@Observable
final class CodeBrowser {
    private static var browsers: [Int64: CodeBrowser] = [:]
    static let resultLimit = 50

    static func shared(for project: Project, model: AppModel) -> CodeBrowser {
        let key = project.id ?? -1
        if let browser = browsers[key] { return browser }
        let browser = CodeBrowser(project: project, model: model)
        browsers[key] = browser
        return browser
    }

    let project: Project
    @ObservationIgnored private unowned let model: AppModel

    private(set) var sources: [CodeSource] = []
    private(set) var source: CodeSource?
    private(set) var snapshot: CodeSnapshot?
    private var tree: CodeTree?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var pins: [String: [Pin]] = [:]
    private(set) var tabs: [String] = []
    private(set) var activePath: String?
    private(set) var focusLine = 1
    private(set) var scrollRequest = 0
    var expanded: Set<String> = []
    var filter = ""

    var isFinderPresented = false
    var finderMode: CodeFinderMode = .files
    var finderQuery = ""
    var finderSelection = 0
    private(set) var textHits: [CodeSearchHit] = []
    private var symbolIndex: [(path: String, symbol: CodeSymbol)]?
    private var documents: [String: CodeDocument] = [:]
    private var fetching: Set<String> = []
    private var searchTask: Task<Void, Never>?

    private init(project: Project, model: AppModel) {
        self.project = project
        self.model = model
    }

    func refreshSources() async {
        sources = model.codeSources(for: project)
        let current = sources.first { $0.id == source?.id } ?? sources.first
        if current != source || snapshot == nil {
            await select(current)
        } else {
            source = current
        }
    }

    func select(_ next: CodeSource?) async {
        let changed = next?.id != source?.id
        source = next
        if changed {
            tabs = []
            activePath = nil
            expanded = []
            filter = ""
            finderQuery = ""
        }
        await reload()
    }

    func reload() async {
        guard let source, let workspace = model.codeWorkspace(for: source, in: project) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await workspace.snapshot()
            guard source.id == self.source?.id else { return }
            snapshot = loaded
            tree = CodeTree(files: loaded.files)
            loadError = nil
            documents = [:]
            symbolIndex = nil
            pins = Dictionary(grouping: model.codePins(for: source), by: \.file)
            tabs = tabs.filter { loaded.files.contains($0) }
            if let activePath, !loaded.files.contains(activePath) { self.activePath = tabs.first }
            if expanded.isEmpty { expanded = Self.directoriesToExpand(loaded) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func directoriesToExpand(_ snapshot: CodeSnapshot) -> Set<String> {
        var directories: Set<String> = []
        for path in snapshot.changes.keys {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                directories.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        return directories
    }

    var rows: [CodeTreeRow] {
        guard let files = snapshot?.files else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.isEmpty else {
            return files.filter { $0.lowercased().contains(needle) }.prefix(500).map {
                CodeTreeRow(path: $0, name: $0, depth: 0, isDirectory: false)
            }
        }
        return tree?.rows(expanded: expanded) ?? []
    }

    func toggle(_ directory: String) {
        if expanded.contains(directory) { expanded.remove(directory) } else { expanded.insert(directory) }
    }

    func directoryHasChanges(_ directory: String) -> Bool {
        snapshot?.changes.keys.contains { $0.hasPrefix(directory + "/") } ?? false
    }

    func change(for path: String) -> CodeFileChange? {
        snapshot?.changes[path]
    }

    func open(_ path: String, line: Int? = nil) {
        if !tabs.contains(path) { tabs.append(path) }
        activePath = path
        focusLine = line ?? pins[path]?.first?.startLine ?? 1
        scrollRequest += 1
        isFinderPresented = false
    }

    func activate(_ path: String) {
        activePath = path
        focusLine = 1
        scrollRequest += 1
    }

    func close(_ path: String) {
        guard let index = tabs.firstIndex(of: path) else { return }
        tabs.remove(at: index)
        if activePath == path {
            activePath = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
    }

    func focus(_ line: Int) {
        focusLine = line
        scrollRequest += 1
    }

    func document(_ path: String) -> CodeDocument {
        if let cached = documents[path] { return cached }
        guard project.isRemote else {
            guard let source else { return .missing }
            let loaded = CodeWorkspace.document(at: source.root.appending(path: path))
            documents[path] = loaded
            return loaded
        }
        fetch(path)
        return .loading
    }

    private func fetch(_ path: String) {
        guard !fetching.contains(path) else { return }
        let source = source ?? model.codeSources(for: project).first
        guard let source, let workspace = model.codeWorkspace(for: source, in: project) else { return }
        fetching.insert(path)
        Task {
            let loaded = await workspace.loadDocument(path)
            fetching.remove(path)
            guard source.id == (self.source ?? source).id else { return }
            documents[path] = loaded
        }
    }

    func lines(_ path: String) -> [String] {
        if case .text(let lines) = document(path) { return lines }
        return []
    }

    func presentFinder(_ mode: CodeFinderMode = .files) {
        finderMode = mode
        finderSelection = 0
        isFinderPresented = true
        if mode == .text { scheduleTextSearch() }
    }

    func queryChanged() {
        finderSelection = 0
        if finderMode == .text { scheduleTextSearch() }
    }

    func modeChanged() {
        finderSelection = 0
        if finderMode == .text { scheduleTextSearch() }
    }

    private func scheduleTextSearch() {
        searchTask?.cancel()
        let query = finderQuery
        guard let source, let files = snapshot?.files, let workspace = model.codeWorkspace(for: source, in: project),
              query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            textHits = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let hits = await workspace.search(query, in: files, limit: Self.resultLimit)
            guard !Task.isCancelled else { return }
            self?.textHits = hits
        }
    }

    var finderResults: [CodeFinderResult] {
        guard let files = snapshot?.files else { return [] }
        switch finderMode {
        case .files:
            let scored = fileMatches(in: files)
            return scored.prefix(Self.resultLimit).map { path, match in
                let cut = path.distance(from: path.startIndex, to: path.lastIndex(of: "/").map(path.index(after:)) ?? path.startIndex)
                return CodeFinderResult(
                    path: path, line: pins[path]?.first?.startLine ?? 1,
                    title: String(path.dropFirst(cut)), titleMatches: match.positions.filter { $0 >= cut }.map { $0 - cut },
                    subtitle: cut == 0 ? "./" : String(path.prefix(cut)), subtitleMatches: match.positions.filter { $0 < cut }
                )
            }
        case .symbols:
            let index = symbols(in: files)
            let scored = index.compactMap { entry in FuzzyMatch.match(finderQuery, in: entry.symbol.name).map { (entry, $0) } }
                .sorted { $0.1.score > $1.1.score }
            return scored.prefix(Self.resultLimit).map { entry, match in
                CodeFinderResult(
                    path: entry.path, line: entry.symbol.line, title: entry.symbol.name, titleMatches: match.positions,
                    subtitle: "\(entry.path):\(entry.symbol.line)", subtitleMatches: []
                )
            }
        case .text:
            return textHits.map { hit in
                let title = String(hit.text.prefix(120))
                return CodeFinderResult(
                    path: hit.path, line: hit.line, title: title,
                    titleMatches: Array(hit.matchStart..<min(hit.matchStart + hit.matchLength, title.count)),
                    subtitle: "\(hit.path):\(hit.line)", subtitleMatches: []
                )
            }
        }
    }

    private func fileMatches(in files: [String]) -> [(String, FuzzyMatch)] {
        let query = finderQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let recent = Array(tabs.reversed())
            let others = files.filter { !tabs.contains($0) }
            return (recent + others).prefix(Self.resultLimit).map { ($0, FuzzyMatch(score: 0, positions: [])) }
        }
        var matches: [(String, FuzzyMatch)] = []
        for path in files {
            if let match = FuzzyMatch.match(query, in: path) { matches.append((path, match)) }
        }
        return matches.sorted { $0.1.score > $1.1.score }
    }

    private func symbols(in files: [String]) -> [(path: String, symbol: CodeSymbol)] {
        if let symbolIndex { return symbolIndex }
        var index: [(path: String, symbol: CodeSymbol)] = []
        let indexed = project.isRemote ? files.filter { documents[$0] != nil } : Array(files.prefix(4000))
        for path in indexed {
            let language = CodeLanguage(path: path)
            guard ![.plain, .markdown, .toml, .json, .yaml].contains(language) else { continue }
            for symbol in CodeOutline.symbols(lines(path), language: language) {
                index.append((path, symbol))
            }
        }
        if !project.isRemote { symbolIndex = index }
        return index
    }

    func moveFinderSelection(_ delta: Int) {
        let count = finderResults.count
        guard count > 0 else { return }
        finderSelection = min(max(finderSelection + delta, 0), count - 1)
    }

    func openSelectedResult() {
        let results = finderResults
        guard results.indices.contains(finderSelection) else { return }
        let result = results[finderSelection]
        open(result.path, line: result.line)
    }
}
