import Foundation
import GRDB

public enum CodeFileStatus: String, Sendable, Hashable {
    case added
    case modified

    public var mark: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        }
    }
}

public struct CodeFileChange: Sendable, Hashable {
    public var status: CodeFileStatus
    public var lines: [ClosedRange<Int>]

    public init(status: CodeFileStatus, lines: [ClosedRange<Int>] = []) {
        self.status = status
        self.lines = lines
    }

    public var addedLineCount: Int {
        lines.reduce(0) { $0 + $1.count }
    }

    public func contains(line: Int) -> Bool {
        lines.contains { $0.contains(line) }
    }
}

public struct CodeSnapshot: Sendable, Hashable {
    public var files: [String]
    public var changes: [String: CodeFileChange]

    public init(files: [String], changes: [String: CodeFileChange]) {
        self.files = files
        self.changes = changes
    }
}

public enum CodeDocument: Sendable, Hashable {
    case text(lines: [String])
    case binary
    case tooLarge(bytes: Int)
    case missing
}

public struct CodeSearchHit: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var text: String
    public var matchStart: Int
    public var matchLength: Int
}

public struct CodeWorkspace: Sendable {
    public static let maxDocumentBytes = 2_000_000

    public let root: URL
    public let baseBranch: String?
    let git: GitClient

    public init(root: URL, baseBranch: String?, git: GitClient) {
        self.root = root
        self.baseBranch = baseBranch
        self.git = git
    }

    public func snapshot() async throws -> CodeSnapshot {
        let tracked = try await lines(of: ["ls-files", "-z"], separator: "\0")
        let untracked = try await lines(of: ["ls-files", "--others", "--exclude-standard", "-z"], separator: "\0")
        let files = Array(Set(tracked + untracked))
            .filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
            .sorted()

        var changes: [String: CodeFileChange] = [:]
        if let reference = try await comparisonReference() {
            let statuses = try await lines(of: ["diff", "--no-renames", "--name-status", "-z", reference], separator: "\0")
            var index = 0
            while index + 1 < statuses.count {
                let code = statuses[index]
                let path = statuses[index + 1]
                index += 2
                if code.hasPrefix("A") { changes[path] = CodeFileChange(status: .added) }
                if code.hasPrefix("M") { changes[path] = CodeFileChange(status: .modified) }
            }
            let diff = try await git.run(["diff", "--no-renames", "--no-color", "-U0", reference], in: root)
            for (path, ranges) in Self.addedLines(inUnifiedDiff: diff) where changes[path] != nil {
                changes[path]?.lines = ranges
            }
        }
        for path in untracked where FileManager.default.fileExists(atPath: root.appending(path: path).path) {
            guard case .text(let lines) = document(path) else {
                changes[path] = CodeFileChange(status: .added)
                continue
            }
            changes[path] = CodeFileChange(status: .added, lines: lines.isEmpty ? [] : [1...lines.count])
        }
        return CodeSnapshot(files: files, changes: changes)
    }

    public func document(_ path: String) -> CodeDocument {
        Self.document(at: root.appending(path: path))
    }

    public static func document(at url: URL) -> CodeDocument {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return .missing }
        guard size <= maxDocumentBytes else { return .tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return .text(lines: lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 })
    }

    public func search(_ needle: String, in files: [String], limit: Int = 200) async -> [CodeSearchHit] {
        let query = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let root = root
        return await Task.detached(priority: .userInitiated) {
            var hits: [CodeSearchHit] = []
            for path in files {
                if Task.isCancelled || hits.count >= limit { break }
                guard case .text(let lines) = Self.document(at: root.appending(path: path)) else { continue }
                for (offset, line) in lines.enumerated() where hits.count < limit {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let range = trimmed.lowercased().range(of: query) else { continue }
                    let start = trimmed.lowercased().distance(from: trimmed.lowercased().startIndex, to: range.lowerBound)
                    hits.append(CodeSearchHit(path: path, line: offset + 1, text: trimmed, matchStart: start, matchLength: query.count))
                }
            }
            return hits
        }.value
    }

    func comparisonReference() async throws -> String? {
        guard let baseBranch, !baseBranch.isEmpty else {
            return (try? await git.run(["rev-parse", "--verify", "HEAD"], in: root)) == nil ? nil : "HEAD"
        }
        let output = try? await git.run(["merge-base", baseBranch, "HEAD"], in: root)
        let base = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return base.isEmpty ? "HEAD" : base
    }

    private func lines(of arguments: [String], separator: Character) async throws -> [String] {
        try await git.run(arguments, in: root).split(separator: separator).map(String.init)
    }

    static func addedLines(inUnifiedDiff diff: String) -> [String: [ClosedRange<Int>]] {
        var result: [String: [ClosedRange<Int>]] = [:]
        var current: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let target = line.dropFirst(4)
                current = target == "/dev/null" ? nil : String(target.hasPrefix("b/") ? target.dropFirst(2) : target)
            } else if line.hasPrefix("@@"), let current,
                      let match = line.firstMatch(of: /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/),
                      let start = Int(match.1) {
                let count = match.2.flatMap { Int($0) } ?? 1
                if count > 0 { result[current, default: []].append(start...(start + count - 1)) }
            }
        }
        return result
    }
}

extension AppDatabase {
    public func pins(agentId: Int64) throws -> [Pin] {
        try writer.read { db in
            try Pin.filter(Column("agentId") == agentId).order(Column("file"), Column("startLine")).fetchAll(db)
        }
    }
}

public struct CodeTreeRow: Sendable, Hashable, Identifiable {
    public let path: String
    public let name: String
    public let depth: Int
    public let isDirectory: Bool

    public init(path: String, name: String, depth: Int, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.depth = depth
        self.isDirectory = isDirectory
    }

    public var id: String { (isDirectory ? "d:" : "f:") + path }
}

public struct CodeTree: Sendable {
    private final class Node: @unchecked Sendable {
        let path: String
        var directories: [String: Node] = [:]
        var files: [String] = []

        init(path: String) {
            self.path = path
        }
    }

    private let root: Node

    public init(files: [String]) {
        let root = Node(path: "")
        for path in files {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                let childPath = node.path.isEmpty ? part : node.path + "/" + part
                if let child = node.directories[part] {
                    node = child
                } else {
                    let child = Node(path: childPath)
                    node.directories[part] = child
                    node = child
                }
            }
            if let name = parts.last { node.files.append(name) }
        }
        self.root = root
    }

    public func rows(expanded: Set<String>) -> [CodeTreeRow] {
        var rows: [CodeTreeRow] = []
        func walk(_ node: Node, depth: Int) {
            for name in node.directories.keys.sorted(by: Self.order) {
                guard let child = node.directories[name] else { continue }
                rows.append(CodeTreeRow(path: child.path, name: name, depth: depth, isDirectory: true))
                if expanded.contains(child.path) { walk(child, depth: depth + 1) }
            }
            for name in node.files.sorted(by: Self.order) {
                rows.append(CodeTreeRow(path: node.path.isEmpty ? name : node.path + "/" + name, name: name, depth: depth, isDirectory: false))
            }
        }
        walk(root, depth: 0)
        return rows
    }

    private static func order(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
