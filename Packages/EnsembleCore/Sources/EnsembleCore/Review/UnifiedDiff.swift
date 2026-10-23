import Foundation

public struct PatchLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case added
        case removed
    }

    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    public var missingNewlineAtEnd: Bool

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?, missingNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.missingNewlineAtEnd = missingNewlineAtEnd
    }
}

public struct PatchHunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var section: String
    public var lines: [PatchLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [PatchLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    public var header: String {
        let range = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return section.isEmpty ? range : "\(range) \(section)"
    }

    public var newLineRange: ClosedRange<Int>? {
        let numbers = lines.compactMap(\.newLine)
        guard let first = numbers.first, let last = numbers.last else { return nil }
        return first...last
    }
}

public enum FileChangeKind: String, Sendable, Hashable, Codable {
    case added
    case modified
    case deleted
    case renamed
    case copied
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public var oldPath: String?
    public var newPath: String?
    public var change: FileChangeKind
    public var isBinary: Bool
    public var similarity: Int?
    public var oldMode: String?
    public var newMode: String?
    public var hunks: [PatchHunk]
    public var isGenerated: Bool
    public var hasUncommittedChanges: Bool
    public var patch: String

    public init(
        oldPath: String?, newPath: String?, change: FileChangeKind, isBinary: Bool = false, similarity: Int? = nil,
        oldMode: String? = nil, newMode: String? = nil, hunks: [PatchHunk] = [], isGenerated: Bool = false,
        hasUncommittedChanges: Bool = false, patch: String = ""
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.change = change
        self.isBinary = isBinary
        self.similarity = similarity
        self.oldMode = oldMode
        self.newMode = newMode
        self.hunks = hunks
        self.isGenerated = isGenerated
        self.hasUncommittedChanges = hasUncommittedChanges
        self.patch = patch
    }

    public var path: String { newPath ?? oldPath ?? "" }
    public var id: String { path }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }

    public var touchedPaths: Set<String> { Set([oldPath, newPath].compactMap(\.self)) }
}

public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var builder: FileBuilder?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                if let finished = builder?.build() { files.append(finished) }
                builder = FileBuilder(header: line)
                continue
            }
            builder?.consume(line)
        }
        if let finished = builder?.build() { files.append(finished) }
        return files
    }

    static func parseHunkHeader(_ line: String) -> PatchHunk? {
        guard line.hasPrefix("@@ -") else { return nil }
        let body = line.dropFirst(3)
        guard let close = body.range(of: " @@") else { return nil }
        let ranges = body[..<close.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
              let old = parseRange(ranges[0].dropFirst()), let new = parseRange(ranges[1].dropFirst()) else { return nil }
        let section = body[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return PatchHunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count, section: section)
    }

    private static func parseRange(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        guard parts.count > 1 else { return (start, 1) }
        guard let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var bytes: [UInt8] = []
        var iterator = Array(path.dropFirst().dropLast().utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escaped = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(UInt8(ascii: "\n"))
            case UInt8(ascii: "t"): bytes.append(UInt8(ascii: "\t"))
            case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func stripPrefix(_ raw: String) -> String? {
        let path = unquote(raw.trimmingCharacters(in: .whitespaces))
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    private struct FileBuilder {
        var file: FileDiff
        var patchLines: [String]
        var hunk: PatchHunk?
        var oldCursor = 0
        var newCursor = 0
        var sawNewFile = false
        var sawDeletedFile = false

        init(header: String) {
            let paths = Self.pathsFromGitHeader(header)
            file = FileDiff(oldPath: paths.old, newPath: paths.new, change: .modified)
            patchLines = [header]
        }

        mutating func consume(_ line: String) {
            patchLines.append(line)
            if hunk != nil, consumeHunkLine(line) { return }
            if let header = UnifiedDiffParser.parseHunkHeader(line) {
                flushHunk()
                hunk = header
                oldCursor = header.oldStart
                newCursor = header.newStart
                return
            }
            consumeHeaderLine(line)
        }

        private mutating func consumeHunkLine(_ line: String) -> Bool {
            guard var current = hunk else { return false }
            if line.hasPrefix("\\") {
                if let last = current.lines.indices.last { current.lines[last].missingNewlineAtEnd = true }
                hunk = current
                return true
            }
            let remainingOld = current.oldStart + current.oldCount - oldCursor
            let remainingNew = current.newStart + current.newCount - newCursor
            guard remainingOld > 0 || remainingNew > 0 else {
                flushHunk()
                return false
            }
            let marker = line.first
            let text = String(line.dropFirst())
            switch marker {
            case "+":
                current.lines.append(PatchLine(kind: .added, text: text, oldLine: nil, newLine: newCursor))
                newCursor += 1
            case "-":
                current.lines.append(PatchLine(kind: .removed, text: text, oldLine: oldCursor, newLine: nil))
                oldCursor += 1
            case " ", nil:
                current.lines.append(PatchLine(kind: .context, text: text, oldLine: oldCursor, newLine: newCursor))
                oldCursor += 1
                newCursor += 1
            default:
                hunk = current
                flushHunk()
                return false
            }
            hunk = current
            return true
        }

        private mutating func flushHunk() {
            if let hunk { file.hunks.append(hunk) }
            hunk = nil
        }

        private mutating func consumeHeaderLine(_ line: String) {
            if line.hasPrefix("new file mode ") {
                sawNewFile = true
                file.newMode = String(line.dropFirst("new file mode ".count))
            } else if line.hasPrefix("deleted file mode ") {
                sawDeletedFile = true
                file.oldMode = String(line.dropFirst("deleted file mode ".count))
            } else if line.hasPrefix("old mode ") {
                file.oldMode = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                file.newMode = String(line.dropFirst("new mode ".count))
            } else if line.hasPrefix("rename from ") {
                file.change = .renamed
                file.oldPath = UnifiedDiffParser.unquote(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                file.change = .renamed
                file.newPath = UnifiedDiffParser.unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("copy from ") {
                file.change = .copied
                file.oldPath = UnifiedDiffParser.unquote(String(line.dropFirst("copy from ".count)))
            } else if line.hasPrefix("copy to ") {
                file.change = .copied
                file.newPath = UnifiedDiffParser.unquote(String(line.dropFirst("copy to ".count)))
            } else if line.hasPrefix("similarity index ") {
                file.similarity = Int(line.dropFirst("similarity index ".count).trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file.isBinary = true
            } else if line.hasPrefix("--- ") {
                let path = UnifiedDiffParser.stripPrefix(String(line.dropFirst(4)))
                if path == nil { sawNewFile = true } else { file.oldPath = path }
            } else if line.hasPrefix("+++ ") {
                let path = UnifiedDiffParser.stripPrefix(String(line.dropFirst(4)))
                if path == nil { sawDeletedFile = true } else { file.newPath = path }
            }
        }

        mutating func build() -> FileDiff {
            flushHunk()
            if sawNewFile {
                file.change = .added
                file.oldPath = nil
            } else if sawDeletedFile {
                file.change = .deleted
                file.newPath = nil
            }
            while patchLines.last?.isEmpty == true { patchLines.removeLast() }
            file.patch = patchLines.joined(separator: "\n")
            file.isGenerated = GeneratedFiles.isGenerated(file.path)
            return file
        }

        static func pathsFromGitHeader(_ header: String) -> (old: String?, new: String?) {
            let rest = String(header.dropFirst("diff --git ".count))
            if rest.hasPrefix("\"") {
                let parts = splitQuoted(rest)
                return (parts.first.flatMap(UnifiedDiffParser.stripPrefix), parts.dropFirst().first.flatMap(UnifiedDiffParser.stripPrefix))
            }
            guard rest.hasPrefix("a/") else { return (nil, nil) }
            let body = rest.dropFirst(2)
            let half = (body.count - 3) / 2
            if half > 0, body.count == half * 2 + 3 {
                let old = String(body.prefix(half))
                let separatorAndNew = body.dropFirst(half)
                if separatorAndNew.hasPrefix(" b/"), String(separatorAndNew.dropFirst(3)) == old {
                    return (old, old)
                }
            }
            if let separator = body.range(of: " b/", options: .backwards) {
                return (String(body[..<separator.lowerBound]), String(body[separator.upperBound...]))
            }
            return (String(body), String(body))
        }

        private static func splitQuoted(_ text: String) -> [String] {
            var parts: [String] = []
            var current = ""
            var inQuotes = false
            var escaping = false
            for character in text {
                if escaping {
                    current.append(character)
                    escaping = false
                } else if character == "\\" && inQuotes {
                    current.append(character)
                    escaping = true
                } else if character == "\"" {
                    current.append(character)
                    inQuotes.toggle()
                } else if character == " " && !inQuotes {
                    if !current.isEmpty { parts.append(current) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { parts.append(current) }
            return parts
        }
    }
}
