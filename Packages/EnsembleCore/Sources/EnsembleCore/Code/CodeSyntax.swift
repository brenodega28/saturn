import Foundation

public enum CodeLanguage: String, Sendable, Hashable, CaseIterable {
    case python
    case typescript
    case javascript
    case swift
    case go
    case rust
    case ruby
    case shell
    case markdown
    case toml
    case yaml
    case json
    case html
    case css
    case plain

    public init(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "py", "pyi": self = .python
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "swift": self = .swift
        case "go": self = .go
        case "rs": self = .rust
        case "rb", "rake": self = .ruby
        case "sh", "bash", "zsh": self = .shell
        case "md", "markdown": self = .markdown
        case "toml": self = .toml
        case "yml", "yaml": self = .yaml
        case "json": self = .json
        case "html", "htm": self = .html
        case "css", "scss": self = .css
        default: self = ["makefile", "dockerfile", "gemfile"].contains(name) ? .shell : .plain
        }
    }

    public var title: String {
        switch self {
        case .python: "Python"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .swift: "Swift"
        case .go: "Go"
        case .rust: "Rust"
        case .ruby: "Ruby"
        case .shell: "Shell"
        case .markdown: "Markdown"
        case .toml: "TOML"
        case .yaml: "YAML"
        case .json: "JSON"
        case .html: "HTML"
        case .css: "CSS"
        case .plain: "Plain text"
        }
    }

    var lineComment: String? {
        switch self {
        case .python, .ruby, .shell, .toml, .yaml: "#"
        case .typescript, .javascript, .swift, .go, .rust, .css: "//"
        case .markdown, .json, .html, .plain: nil
        }
    }

    var keywords: Set<String> {
        switch self {
        case .python:
            ["def", "class", "return", "import", "from", "with", "if", "not", "raise", "for", "in", "as", "is", "None", "True", "False", "self", "and", "or", "elif", "else", "try", "except", "finally", "pass", "lambda", "await", "async", "yield", "while", "break", "continue", "global", "assert", "del"]
        case .typescript, .javascript:
            ["import", "from", "export", "default", "function", "return", "const", "let", "var", "if", "else", "for", "while", "of", "in", "new", "class", "extends", "type", "interface", "async", "await", "try", "catch", "finally", "throw", "null", "undefined", "true", "false", "this", "typeof", "switch", "case", "break", "continue", "enum", "as", "implements"]
        case .swift:
            ["import", "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "case", "switch", "for", "in", "while", "try", "throw", "throws", "async", "await", "public", "private", "fileprivate", "internal", "static", "self", "Self", "nil", "true", "false", "init", "some", "any", "where", "defer", "do", "catch", "mutating", "final", "override", "typealias", "actor", "nonisolated"]
        case .go:
            ["package", "import", "func", "return", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "switch", "case", "go", "defer", "chan", "map", "nil", "true", "false", "break", "continue", "select"]
        case .rust:
            ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "return", "if", "else", "match", "for", "in", "while", "loop", "self", "Self", "true", "false", "async", "await", "move", "where", "crate", "const", "static", "type"]
        case .ruby:
            ["def", "class", "module", "end", "if", "else", "elsif", "unless", "return", "do", "while", "nil", "true", "false", "self", "require", "yield", "begin", "rescue", "ensure", "attr_reader", "attr_accessor"]
        case .shell:
            ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "in"]
        case .yaml, .json:
            ["true", "false", "null"]
        case .markdown, .toml, .html, .css, .plain:
            []
        }
    }

    var definitionKeywords: Set<String> {
        ["def", "function", "func", "fn"]
    }

    var typeKeywords: Set<String> {
        ["class", "type", "struct", "enum", "protocol", "interface", "trait", "extension", "impl", "module", "actor"]
    }
}

public struct CodeToken: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case plain
        case keyword
        case string
        case comment
        case number
        case function
        case type
        case decorator
        case heading
        case punctuation
    }

    public var text: String
    public var kind: Kind

    public init(_ text: String, _ kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

public enum CodeTokenizer {
    public static func tokens(_ line: String, language: CodeLanguage) -> [CodeToken] {
        switch language {
        case .markdown: return markdown(line)
        case .toml: return toml(line)
        case .plain: return line.isEmpty ? [] : [CodeToken(line, .plain)]
        default: return code(line, language: language)
        }
    }

    private static func markdown(_ line: String) -> [CodeToken] {
        if line.hasPrefix("#") { return [CodeToken(line, .heading)] }
        if let match = line.firstMatch(of: /^(\s*(?:[-*]|\d+\.)\s)(.*)$/) {
            return [CodeToken(String(match.1), .keyword), CodeToken(String(match.2), .plain)]
        }
        return line.isEmpty ? [] : [CodeToken(line, .plain)]
    }

    private static func toml(_ line: String) -> [CodeToken] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return [CodeToken(line, .comment)] }
        if trimmed.hasPrefix("[") { return [CodeToken(line, .type)] }
        if let match = line.firstMatch(of: /^(\s*[\w.-]+)(\s*=\s*)(.*)$/) {
            let value = String(match.3)
            let kind: CodeToken.Kind = value.hasPrefix("\"") || value.hasPrefix("'") ? .string : .number
            return [CodeToken(String(match.1), .function), CodeToken(String(match.2), .punctuation), CodeToken(value, kind)]
        }
        return line.isEmpty ? [] : [CodeToken(line, trimmed.hasPrefix("\"") ? .string : .plain)]
    }

    private static func code(_ line: String, language: CodeLanguage) -> [CodeToken] {
        let keywords = language.keywords
        let comment = language.lineComment
        var tokens: [CodeToken] = []
        var previousWord = ""
        var index = line.startIndex

        func append(_ text: Substring, _ kind: CodeToken.Kind) {
            if let last = tokens.last, last.kind == kind, kind == .plain || kind == .punctuation {
                tokens[tokens.count - 1].text += text
            } else {
                tokens.append(CodeToken(String(text), kind))
            }
        }

        while index < line.endIndex {
            let rest = line[index...]
            let character = line[index]
            if let comment, rest.hasPrefix(comment) {
                append(rest, .comment)
                break
            }
            if language != .python, language != .ruby, language != .shell, rest.hasPrefix("/*") {
                let end = rest.range(of: "*/").map { $0.upperBound } ?? line.endIndex
                append(line[index..<end], .comment)
                index = end
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                var end = line.index(after: index)
                while end < line.endIndex, line[end] != character {
                    if line[end] == "\\" { end = line.index(after: end) }
                    if end < line.endIndex { end = line.index(after: end) }
                }
                if end < line.endIndex { end = line.index(after: end) }
                append(line[index..<end], .string)
                index = end
                previousWord = ""
                continue
            }
            if character == "@", let match = rest.prefixMatch(of: /@[\w.]+/) {
                append(match.output, .decorator)
                index = match.range.upperBound
                continue
            }
            if character.isNumber, let match = rest.prefixMatch(of: /\d+(?:\.\d+)?/) {
                append(match.output, .number)
                index = match.range.upperBound
                previousWord = ""
                continue
            }
            if character.isLetter || character == "_" || character == "$", let match = rest.prefixMatch(of: /[A-Za-z_$][\w$]*/) {
                let word = String(match.output)
                let kind: CodeToken.Kind
                if keywords.contains(word) {
                    kind = .keyword
                } else if language.definitionKeywords.contains(previousWord) {
                    kind = .function
                } else if language.typeKeywords.contains(previousWord) || word.first?.isUppercase == true {
                    kind = .type
                } else {
                    kind = .plain
                }
                append(match.output, kind)
                index = match.range.upperBound
                previousWord = word
                continue
            }
            append(line[index...index], character.isWhitespace ? .plain : .punctuation)
            if !character.isWhitespace { previousWord = "" }
            index = line.index(after: index)
        }
        return tokens
    }
}

public struct CodeSymbol: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case type
        case function
        case heading
        case section
    }

    public var name: String
    public var line: Int
    public var kind: Kind
    public var depth: Int

    public var id: Int { line }

    public init(name: String, line: Int, kind: Kind, depth: Int) {
        self.name = name
        self.line = line
        self.kind = kind
        self.depth = depth
    }
}

public enum CodeOutline {
    public static func symbols(_ lines: [String], language: CodeLanguage) -> [CodeSymbol] {
        lines.enumerated().compactMap { offset, line in
            symbol(line, number: offset + 1, language: language)
        }
    }

    static func symbol(_ line: String, number: Int, language: CodeLanguage) -> CodeSymbol? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let depth = indent > 0 ? 1 : 0
        switch language {
        case .python:
            guard let match = line.firstMatch(of: /^\s*(?:async\s+)?(class|def)\s+(\w+)/) else { return nil }
            return CodeSymbol(name: String(match.2), line: number, kind: match.1 == "class" ? .type : .function, depth: depth)
        case .typescript, .javascript:
            if let match = line.firstMatch(of: /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(function|class|type|interface)\s+(\w+)/) {
                return CodeSymbol(name: String(match.2), line: number, kind: match.1 == "function" ? .function : .type, depth: depth)
            }
            if let match = line.firstMatch(of: /^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?\(/) {
                return CodeSymbol(name: String(match.1), line: number, kind: .function, depth: depth)
            }
            return nil
        case .swift:
            guard let match = line.firstMatch(of: /^\s*(?:(?:public|private|fileprivate|internal|open|static|final|override|mutating|nonisolated|@\w+)\s+)*(struct|class|enum|protocol|extension|actor|func)\s+([\w.]+)/) else { return nil }
            return CodeSymbol(name: String(match.2), line: number, kind: match.1 == "func" ? .function : .type, depth: depth)
        case .go:
            guard let match = line.firstMatch(of: /^(func|type)\s+(?:\([^)]*\)\s*)?(\w+)/) else { return nil }
            return CodeSymbol(name: String(match.2), line: number, kind: match.1 == "func" ? .function : .type, depth: 0)
        case .rust:
            guard let match = line.firstMatch(of: /^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(fn|struct|enum|trait|impl)\s+(\w+)/) else { return nil }
            return CodeSymbol(name: String(match.2), line: number, kind: match.1 == "fn" ? .function : .type, depth: depth)
        case .ruby:
            guard let match = line.firstMatch(of: /^\s*(class|module|def)\s+([\w.:]+)/) else { return nil }
            return CodeSymbol(name: String(match.2), line: number, kind: match.1 == "def" ? .function : .type, depth: depth)
        case .markdown:
            guard let match = line.firstMatch(of: /^(#+)\s+(.*)/) else { return nil }
            return CodeSymbol(name: String(match.2), line: number, kind: .heading, depth: match.1.count - 1)
        case .toml:
            guard let match = line.firstMatch(of: /^\[+([^\]]+)\]+/) else { return nil }
            return CodeSymbol(name: String(match.1), line: number, kind: .section, depth: 0)
        default:
            return nil
        }
    }
}

public struct FuzzyMatch: Sendable, Hashable {
    public var score: Double
    public var positions: [Int]

    public init(score: Double, positions: [Int]) {
        self.score = score
        self.positions = positions
    }

    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        let characters = Array(candidate)
        let lowered = Array(candidate.lowercased())
        guard lowered.count == characters.count else { return nil }
        let nameStart = (characters.lastIndex(of: "/") ?? -1) + 1
        var positions: [Int] = []
        var score = 0.0
        var last = -2
        var next = 0
        for index in characters.indices where next < needle.count {
            guard lowered[index] == needle[next] else { continue }
            positions.append(index)
            score += 1
            if index == last + 1 { score += 5 }
            if index >= nameStart { score += 2 }
            if index == 0 || "/_.-".contains(characters[index - 1]) { score += 4 }
            last = index
            next += 1
        }
        guard next == needle.count else { return nil }
        return FuzzyMatch(score: score - Double(characters.count) * 0.05, positions: positions)
    }
}
