import Foundation

public struct Page<Kind: Codable & Hashable & Sendable>: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public struct PageList<Kind: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public private(set) var pages: [Page<Kind>]
    public private(set) var activeID: UUID?

    public init(pages: [Page<Kind>] = [], activeID: UUID? = nil) {
        self.pages = pages
        self.activeID = activeID.flatMap { id in pages.contains { $0.id == id } ? id : nil } ?? pages.first?.id
    }

    public var active: Page<Kind>? {
        pages.first { $0.id == activeID }
    }

    public var activeIndex: Int? {
        pages.firstIndex { $0.id == activeID }
    }

    public var isEmpty: Bool { pages.isEmpty }

    public func page(matching kind: Kind) -> Page<Kind>? {
        page { $0 == kind }
    }

    public func page(where matches: (Kind) -> Bool) -> Page<Kind>? {
        pages.first { matches($0.kind) }
    }

    @discardableResult
    public mutating func open(_ kind: Kind, unique: Bool = true) -> UUID {
        open(kind, sameAs: unique ? { $0 == kind } : { _ in false })
    }

    @discardableResult
    public mutating func open(_ kind: Kind, sameAs matches: (Kind) -> Bool) -> UUID {
        if let existing = page(where: matches) {
            activeID = existing.id
            return existing.id
        }
        let page = Page(kind: kind)
        pages.append(page)
        activeID = page.id
        return page.id
    }

    @discardableResult
    public mutating func show(_ kind: Kind, replacingActiveWhen replaceable: (Kind) -> Bool) -> UUID {
        if let existing = page(matching: kind) {
            activeID = existing.id
            return existing.id
        }
        if let index = activeIndex, replaceable(pages[index].kind) {
            pages[index].kind = kind
            return pages[index].id
        }
        return open(kind)
    }

    public mutating func replace(_ id: UUID, with kind: Kind) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if let existing = page(matching: kind), existing.id != id {
            close(id)
            activeID = existing.id
        } else {
            pages[index].kind = kind
        }
    }

    public mutating func focus(_ id: UUID) {
        guard pages.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    public mutating func close(_ id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        guard activeID == id else { return }
        activeID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
    }

    public mutating func closeOthers(_ id: UUID) {
        guard pages.contains(where: { $0.id == id }) else { return }
        pages.removeAll { $0.id != id }
        activeID = id
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter(pages.indices.contains).map { pages[$0] }
        guard !moving.isEmpty else { return }
        let target = destination - source.count { $0 < destination }
        pages.remove(atOffsets: source)
        pages.insert(contentsOf: moving, at: min(max(target, 0), pages.count))
    }

    public mutating func selectNext() {
        step(by: 1)
    }

    public mutating func selectPrevious() {
        step(by: -1)
    }

    public mutating func select(index: Int) {
        guard pages.indices.contains(index) else { return }
        activeID = pages[index].id
    }

    public mutating func retain(where keep: (Page<Kind>) -> Bool) {
        let activeIndex = activeIndex
        pages.removeAll { !keep($0) }
        guard let activeIndex, !pages.contains(where: { $0.id == activeID }) else { return }
        activeID = pages.isEmpty ? nil : pages[min(activeIndex, pages.count - 1)].id
    }

    private mutating func step(by offset: Int) {
        guard !pages.isEmpty else { return }
        let current = activeIndex ?? 0
        activeID = pages[(current + offset + pages.count) % pages.count].id
    }
}

private extension Array {
    mutating func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) where indices.contains(index) {
            remove(at: index)
        }
    }
}
