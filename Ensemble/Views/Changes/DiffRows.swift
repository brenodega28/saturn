import EnsembleCore
import Foundation

struct UnifiedRow: Identifiable {
    enum Content {
        case hunk(String)
        case line(PatchLine, pinned: Bool)
        case pin(Pin)
    }

    let id: Int
    let content: Content
}

struct SplitSide {
    let line: PatchLine
    let pinned: Bool
}

struct SplitRow: Identifiable {
    enum Content {
        case hunk(String)
        case pair(left: SplitSide?, right: SplitSide?)
        case pin(Pin)
    }

    let id: Int
    let content: Content
}

struct DiffRows {
    let unified: [UnifiedRow]
    let split: [SplitRow]
    let unplacedPins: [Pin]
    let totalLines: Int

    init(diff: FileDiff, pins: [Pin], lineLimit: Int?) {
        var placed = Set<Int64>()
        var unified: [UnifiedRow] = []
        var shownLines = 0
        var total = 0
        var nextID = 0
        func append(_ content: UnifiedRow.Content) {
            unified.append(UnifiedRow(id: nextID, content: content))
            nextID += 1
        }
        for hunk in diff.hunks {
            total += hunk.lines.count
            guard lineLimit.map({ shownLines < $0 }) ?? true else { continue }
            append(.hunk(hunk.header))
            let anchors = Self.anchors(for: pins, in: hunk)
            for line in hunk.lines {
                guard lineLimit.map({ shownLines < $0 }) ?? true else { break }
                shownLines += 1
                append(.line(line, pinned: pins.contains { $0.covers(line) }))
                for pin in anchors[Self.key(line)] ?? [] {
                    guard let id = pin.id, placed.insert(id).inserted else { continue }
                    append(.pin(pin))
                }
            }
        }
        self.unified = unified
        self.split = Self.pairUp(unified)
        self.unplacedPins = pins.filter { pin in pin.id.map { !placed.contains($0) } ?? true }
        self.totalLines = total
    }

    private static func key(_ line: PatchLine) -> String {
        "\(line.oldLine ?? -1):\(line.newLine ?? -1)"
    }

    private static func anchors(for pins: [Pin], in hunk: PatchHunk) -> [String: [Pin]] {
        var result: [String: [Pin]] = [:]
        for pin in pins {
            guard let anchor = hunk.lines.last(where: pin.covers) else { continue }
            result[key(anchor), default: []].append(pin)
        }
        return result
    }

    private static func pairUp(_ rows: [UnifiedRow]) -> [SplitRow] {
        var result: [SplitRow] = []
        var index = 0
        func append(_ content: SplitRow.Content) {
            result.append(SplitRow(id: result.count, content: content))
        }
        while index < rows.count {
            switch rows[index].content {
            case .hunk(let header):
                append(.hunk(header))
                index += 1
            case .pin(let pin):
                append(.pin(pin))
                index += 1
            case .line(let line, let pinned) where line.kind == .context:
                append(.pair(left: SplitSide(line: line, pinned: pinned), right: SplitSide(line: line, pinned: pinned)))
                index += 1
            case .line:
                var removed: [SplitSide] = []
                var added: [SplitSide] = []
                while index < rows.count, case .line(let line, let pinned) = rows[index].content, line.kind == .removed {
                    removed.append(SplitSide(line: line, pinned: pinned))
                    index += 1
                }
                while index < rows.count, case .line(let line, let pinned) = rows[index].content, line.kind == .added {
                    added.append(SplitSide(line: line, pinned: pinned))
                    index += 1
                }
                for offset in 0..<max(removed.count, added.count) {
                    append(.pair(left: removed[safe: offset], right: added[safe: offset]))
                }
            }
        }
        return result
    }
}

struct LineTarget: Hashable {
    let side: PinSide
    let line: Int
}

struct LineSelection: Equatable {
    let entryID: String
    let side: PinSide
    let anchor: Int
    var head: Int

    var range: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }

    func contains(_ line: PatchLine) -> Bool {
        guard let target = line.commentTarget else { return false }
        return target.side == side && range.contains(target.line)
    }

    static func next(after current: LineSelection?, clicking target: LineTarget, in entryID: String, extending: Bool) -> LineSelection {
        if extending, var current, current.entryID == entryID, current.side == target.side {
            current.head = target.line
            return current
        }
        return LineSelection(entryID: entryID, side: target.side, anchor: target.line, head: target.line)
    }
}

extension PatchLine {
    var commentTarget: LineTarget? {
        switch kind {
        case .removed: oldLine.map { LineTarget(side: .old, line: $0) }
        case .added, .context: newLine.map { LineTarget(side: .new, line: $0) }
        }
    }

    func number(on side: PinSide) -> Int? {
        switch side {
        case .new: kind == .removed ? nil : newLine
        case .old: kind == .added ? nil : oldLine
        }
    }
}

extension Pin {
    func covers(_ line: PatchLine) -> Bool {
        line.number(on: side).map(lineRange.contains) ?? false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
