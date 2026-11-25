import SaturnCore
import Foundation
import Observation

enum MainPageKind: Codable, Hashable, Sendable {
    case chat(chatID: Int64?, project: ProjectRef)
    case newChat(draftID: UUID, project: ProjectRef)
    case terminal(project: ProjectRef, directory: String)
    case code(project: ProjectRef, path: String)
    case tool(MainTool, project: ProjectRef?)
    case run(Int64, daemon: DaemonID)
    case agent(Int64, daemon: DaemonID)
    case spec(path: String, project: ProjectRef)

    var isChat: Bool {
        switch self {
        case .chat, .newChat: true
        default: false
        }
    }

    var draftID: UUID? {
        if case .newChat(let draftID, _) = self { return draftID }
        return nil
    }

    var isLegacyNewChat: Bool {
        if case .chat(nil, _) = self { return true }
        return false
    }

    var chatID: Int64? {
        if case .chat(let chatID, _) = self { return chatID }
        return nil
    }

    var project: ProjectRef? {
        switch self {
        case .chat(_, let project), .newChat(_, let project), .terminal(let project, _), .code(let project, _), .spec(_, let project): project
        case .tool(_, let project): project
        case .run, .agent: nil
        }
    }

    var daemon: DaemonID? {
        switch self {
        case .run(_, let daemon), .agent(_, let daemon): daemon
        default: project?.daemon
        }
    }

    func shows(chat chatID: Int64, on daemon: DaemonID) -> Bool {
        self.chatID == chatID && self.daemon == daemon
    }
}

private enum LegacyPageKind: Codable, Hashable, Sendable {
    case chat(chatID: Int64?, projectID: Int64)
    case terminal(projectID: Int64, directory: String)
    case code(projectID: Int64, path: String)
    case tool(MainTool, projectID: Int64?)
    case run(Int64)
    case agent(Int64)
    case spec(path: String, projectID: Int64)

    func tagged(_ daemon: DaemonID) -> MainPageKind {
        let ref = { ProjectRef(daemon: daemon, id: $0) }
        return switch self {
        case .chat(let chatID, let projectID): .chat(chatID: chatID, project: ref(projectID))
        case .terminal(let projectID, let directory): .terminal(project: ref(projectID), directory: directory)
        case .code(let projectID, let path): .code(project: ref(projectID), path: path)
        case .tool(let tool, let projectID): .tool(tool, project: projectID.map(ref))
        case .run(let id): .run(id, daemon: daemon)
        case .agent(let id): .agent(id, daemon: daemon)
        case .spec(let path, let projectID): .spec(path: path, project: ref(projectID))
        }
    }
}

typealias MainPage = Page<MainPageKind>

enum SideBarTab: String, Codable, CaseIterable {
    case summary
    case log

    var title: String {
        switch self {
        case .summary: "Summary"
        case .log: "Log"
        }
    }
}

@MainActor
@Observable
final class MainPages {
    private struct Saved: Codable {
        var list: PageList<MainPageKind>
        var isSideBarOpen: Bool
        var sideBarTab: SideBarTab
    }

    private struct LegacySaved: Codable {
        var list: PageList<LegacyPageKind>
        var isSideBarOpen: Bool
        var sideBarTab: SideBarTab
    }

    static let storageKey = "pages.all"
    static let migratedKey = "pages.migratedFromDaemonKeys"

    private(set) var list = PageList<MainPageKind>()
    var isSideBarOpen = true {
        didSet { save() }
    }
    var sideBarTab = SideBarTab.summary {
        didSet { save() }
    }
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored var onActivate: ((MainPage?) -> Void)?
    @ObservationIgnored var onClose: ((MainPage) -> Void)?

    init(storageKey: String = MainPages.storageKey, legacyDaemons: [DaemonID] = []) {
        self.storageKey = storageKey
        load()
        migrate(legacyDaemons)
    }

    var pages: [MainPage] { list.pages }
    var activeID: UUID? { list.activeID }
    var active: MainPage? { list.active }

    func page(showing chatID: Int64, on daemon: DaemonID) -> MainPage? {
        pages.first { $0.kind.shows(chat: chatID, on: daemon) }
    }

    func page(showingDraft draftID: UUID) -> MainPage? {
        pages.first { $0.kind.draftID == draftID }
    }

    @discardableResult
    func open(_ kind: MainPageKind, unique: Bool = true) -> UUID {
        update { $0.open(kind, unique: unique) }
    }

    @discardableResult
    func open(_ kind: MainPageKind, sameAs matches: (MainPageKind) -> Bool) -> UUID {
        update { $0.open(kind, sameAs: matches) }
    }

    @discardableResult
    func showChat(_ kind: MainPageKind) -> UUID {
        update { $0.show(kind, replacingActiveWhen: \.isChat) }
    }

    func replace(_ id: UUID, with kind: MainPageKind) {
        update { $0.replace(id, with: kind) }
    }

    func focus(_ id: UUID) {
        update { $0.focus(id) }
    }

    func close(_ id: UUID) {
        update { $0.close(id) }
    }

    func closeActive() {
        if let activeID { close(activeID) }
    }

    func closeOthers(_ id: UUID) {
        update { $0.closeOthers(id) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { $0.move(fromOffsets: source, toOffset: destination) }
    }

    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func selectNext() {
        update { $0.selectNext() }
    }

    func selectPrevious() {
        update { $0.selectPrevious() }
    }

    func select(index: Int) {
        update { $0.select(index: index) }
    }

    func retain(where keep: (MainPage) -> Bool) {
        update { $0.retain(where: keep) }
    }

    @discardableResult
    private func update<Value>(_ change: (inout PageList<MainPageKind>) -> Value) -> Value {
        let before = list
        var next = list
        let result = change(&next)
        guard next != before else { return result }
        list = next
        let remaining = Set(next.pages.map(\.id))
        for page in before.pages where !remaining.contains(page.id) {
            onClose?(page)
        }
        save()
        if next.active != before.active { onActivate?(next.active) }
        return result
    }

    private func load() {
        let saved = AppDefaults.store.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        list = saved.map { PageList(pages: $0.list.pages, activeID: $0.list.activeID) } ?? PageList()
        isSideBarOpen = saved?.isSideBarOpen ?? true
        sideBarTab = saved?.sideBarTab ?? .summary
    }

    private func migrate(_ daemons: [DaemonID]) {
        let defaults = AppDefaults.store
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        var pages = list.pages
        var activeID = list.activeID
        for daemon in daemons {
            let key = "pages.\(daemon.uuidString.lowercased())"
            guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(LegacySaved.self, from: data) else { continue }
            let migrated = saved.list.pages.map { MainPage(id: $0.id, kind: $0.kind.tagged(daemon)) }
            pages += migrated.filter { page in !pages.contains { $0.id == page.id || $0.kind == page.kind } }
            if activeID == nil { activeID = saved.list.activeID }
            if list.pages.isEmpty, daemons.first == daemon {
                isSideBarOpen = saved.isSideBarOpen
                sideBarTab = saved.sideBarTab
            }
        }
        list = PageList(pages: pages, activeID: activeID)
        save()
    }

    private func save() {
        let saved = Saved(list: list, isSideBarOpen: isSideBarOpen, sideBarTab: sideBarTab)
        AppDefaults.store.set(try? JSONEncoder().encode(saved), forKey: storageKey)
    }
}
