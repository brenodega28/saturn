import Foundation

public struct MarkdownListItem: Sendable, Hashable {
    public var text: String
    public var depth: Int
    public var number: Int?
    public var isChecked: Bool?

    public init(text: String, depth: Int = 0, number: Int? = nil, isChecked: Bool? = nil) {
        self.text = text
        self.depth = depth
        self.number = number
        self.isChecked = isChecked
    }
}

public enum MarkdownTableAlignment: Sendable, Hashable {
    case leading
    case center
    case trailing
}

public indirect enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String?, code: String, isClosed: Bool)
    case table(header: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case rule
}

public enum MarkdownParser {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var parser = LineParser(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return parser.parse()
    }

    static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in row {
            if isEscaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func alignments(_ line: String) -> [MarkdownTableAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var result: [MarkdownTableAlignment] = []
        for part in parts {
            guard part.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }
}

public enum MarkdownFrontMatter {
    public static func split(_ text: String) -> (fields: [(key: String, value: String)], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.first, Self.isDelimiter(first, opening: true),
              let closing = lines.indices.dropFirst().first(where: { Self.isDelimiter(lines[$0], opening: false) }),
              let fields = Self.fields(lines[1..<closing]) else { return ([], text) }
        let body = lines[(closing + 1)...].drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (fields, body.joined(separator: "\n"))
    }

    private static func isDelimiter(_ line: String, opening: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
        return trimmed == "---" || (!opening && trimmed == "...")
    }

    private static func fields(_ lines: ArraySlice<String>) -> [(key: String, value: String)]? {
        var fields: [(key: String, value: String)] = []
        var items: [String] = []
        func finishList() {
            guard !items.isEmpty, !fields.isEmpty else { return }
            fields[fields.count - 1].value = items.joined(separator: ", ")
            items = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let item = trimmed.wholeMatch(of: /-(?:[ \t]+(.*))?/) {
                guard let last = fields.last, last.value.isEmpty || !items.isEmpty else { return nil }
                items.append(unquoted(item.1.map(String.init) ?? ""))
            } else if let pair = trimmed.wholeMatch(of: /([A-Za-z0-9_][A-Za-z0-9_ .-]*?)[ \t]*:(?:[ \t]+(.*))?[ \t]*/) {
                finishList()
                fields.append((String(pair.1), scalar(pair.2.map(String.init) ?? "")))
            } else {
                return nil
            }
        }
        finishList()
        return fields.isEmpty ? nil : fields
    }

    private static func scalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), value.hasSuffix("]") {
            return value.dropFirst().dropLast().split(separator: ",")
                .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        return unquoted(value)
    }

    private static func unquoted(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return value }
        return String(value.dropFirst().dropLast())
    }
}

private struct Fence {
    let marker: Character
    let length: Int
    let language: String?

    init?(_ line: String) {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        marker = first
        length = run.count
        language = info.split(separator: " ").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    func closes(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == marker }
    }
}

private struct ListMarker {
    let indent: Int
    let number: Int?
    let text: String

    init?(_ line: String) {
        guard let match = line.wholeMatch(of: /([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?/) else { return nil }
        let rest = match.3.map(String.init) ?? ""
        let bullet = String(match.2)
        if match.3 == nil, bullet.count == 1 { return nil }
        indent = match.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        number = bullet.first?.isNumber == true ? Int(bullet.dropLast()) : nil
        text = rest
    }
}

private struct LineParser {
    let lines: [String]
    var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func parse() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            } else if let fence = Fence(line) {
                blocks.append(code(fence))
            } else if let heading = Self.heading(line) {
                blocks.append(heading)
                index += 1
            } else if Self.isRule(line) {
                blocks.append(.rule)
                index += 1
            } else if Self.isQuote(line) {
                blocks.append(quote())
            } else if ListMarker(line) != nil {
                blocks.append(list())
            } else if isTableStart(at: index) {
                blocks.append(table())
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks
    }

    private mutating func code(_ fence: Fence) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count {
            if fence.closes(lines[index]) {
                index += 1
                return .code(language: fence.language, code: body.joined(separator: "\n"), isClosed: true)
            }
            body.append(lines[index])
            index += 1
        }
        return .code(language: fence.language, code: body.joined(separator: "\n"), isClosed: false)
    }

    private mutating func quote() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count, Self.isQuote(lines[index]) {
            var line = lines[index].drop { $0 == " " }.dropFirst()
            if line.first == " " { line = line.dropFirst() }
            body.append(String(line))
            index += 1
        }
        var nested = LineParser(lines: body)
        return .quote(nested.parse())
    }

    private mutating func list() -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        var indents: [Int] = []
        let ordered = ListMarker(lines[index])?.number != nil
        while index < lines.count {
            let line = lines[index]
            if let marker = ListMarker(line), !Self.isRule(line) {
                if !items.isEmpty, marker.indent <= (indents.first ?? 0), (marker.number != nil) != ordered { break }
                while let last = indents.last, last > marker.indent { indents.removeLast() }
                if indents.last.map({ $0 < marker.indent }) ?? true { indents.append(marker.indent) }
                var text = marker.text
                var checked: Bool?
                if let task = text.prefixMatch(of: /\[([ xX])\][ \t]+/) {
                    checked = task.1 != " "
                    text = String(text[task.range.upperBound...])
                }
                items.append(MarkdownListItem(text: text, depth: indents.count - 1, number: marker.number, isChecked: checked))
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let next = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard let next, ListMarker(next) != nil || next.first == " " || next.first == "\t" else { break }
                index += 1
            } else if !items.isEmpty, line.first == " " || line.first == "\t", Fence(line) == nil {
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        return .list(ordered: ordered, items: items)
    }

    private func isTableStart(at position: Int) -> Bool {
        guard position + 1 < lines.count, lines[position].contains("|") else { return false }
        guard let alignments = MarkdownParser.alignments(lines[position + 1]) else { return false }
        return lines[position + 1].contains("|") || alignments.count > 1
    }

    private mutating func table() -> MarkdownBlock {
        let header = MarkdownParser.cells(lines[index])
        let alignments = MarkdownParser.alignments(lines[index + 1]) ?? []
        index += 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            var row = MarkdownParser.cells(lines[index])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        let paddedAlignments = Array((alignments + Array(repeating: .leading, count: max(0, header.count - alignments.count))).prefix(header.count))
        return .table(header: header, alignments: paddedAlignments, rows: rows)
    }

    private mutating func paragraph() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if !body.isEmpty, Self.startsBlock(line) || isTableStart(at: index) { break }
            body.append(line)
            index += 1
        }
        return .paragraph(body.joined(separator: "\n"))
    }

    private static func startsBlock(_ line: String) -> Bool {
        Fence(line) != nil || heading(line) != nil || isRule(line) || isQuote(line) || ListMarker(line) != nil
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        guard let match = line.wholeMatch(of: /[ ]{0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*/) else { return nil }
        var text = match.2.map(String.init) ?? ""
        if let closing = text.firstMatch(of: /[ \t]+#+$/) { text = String(text[..<closing.range.lowerBound]) }
        return .heading(level: match.1.count, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isQuote(_ line: String) -> Bool {
        line.drop { $0 == " " }.first == ">"
    }
}
