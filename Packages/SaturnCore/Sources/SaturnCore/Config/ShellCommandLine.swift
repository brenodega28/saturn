import Foundation

struct ShellCommandLine {
    struct Command: Hashable {
        var words: [String] = []
        var redirects: [String] = []

        var text: String { words.joined(separator: " ") }
        var isEmpty: Bool { words.isEmpty && redirects.isEmpty }
    }

    let commands: [Command]

    init(_ source: String) {
        var parser = ShellParser(Array(source))
        commands = parser.parse(until: nil)
    }
}

private struct ShellParser {
    struct Heredoc {
        var delimiter: String
        var expands: Bool
        var stripsTabs: Bool
    }

    static let operators: Set<Character> = [" ", "\t", "\n", ";", "&", "|", "(", ")", "<", ">"]

    let characters: [Character]
    var index = 0
    var heredocs: [Heredoc] = []

    init(_ characters: [Character]) {
        self.characters = characters
    }

    func peek(_ offset: Int = 0) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    mutating func skipBlanks() {
        while let character = peek(), character == " " || character == "\t" { index += 1 }
    }

    mutating func parse(until closer: Character?) -> [ShellCommandLine.Command] {
        var commands: [ShellCommandLine.Command] = []
        var current = ShellCommandLine.Command()
        var depth = 0
        func finish() {
            if !current.isEmpty { commands.append(current) }
            current = ShellCommandLine.Command()
        }
        while let character = peek() {
            let next = peek(1)
            switch character {
            case " ", "\t":
                index += 1
            case ")" where depth == 0 && closer == ")":
                index += 1
                finish()
                return commands
            case "\n":
                index += 1
                finish()
                commands += readHeredocBodies()
            case "#":
                while let skipped = peek(), skipped != "\n" { index += 1 }
            case "&" where next == ">":
                readRedirect(into: &current, commands: &commands)
            case ";", "&", "|":
                index += 1
                if next == character || (character == "|" && next == "&") { index += 1 }
                finish()
            case "(":
                index += 1
                depth += 1
                finish()
            case ")":
                index += 1
                depth = max(0, depth - 1)
                finish()
            case "<":
                readInput(into: &current, commands: &commands)
            case ">":
                readRedirect(into: &current, commands: &commands)
            default:
                if let word = readWord(into: &commands) { current.words.append(word) }
            }
        }
        finish()
        return commands
    }

    mutating func readInput(into current: inout ShellCommandLine.Command, commands: inout [ShellCommandLine.Command]) {
        switch (peek(1), peek(2)) {
        case ("(", _):
            index += 2
            commands += parse(until: ")")
            current.words.append("<(…)")
        case ("<", "<"):
            index += 3
            skipBlanks()
            _ = readWord(into: &commands)
        case ("<", _):
            index += 2
            readHeredocStart(commands: &commands)
        default:
            index += 1
            if peek() == "&" { index += 1 }
            skipBlanks()
            _ = readWord(into: &commands)
        }
    }

    mutating func readRedirect(into current: inout ShellCommandLine.Command, commands: inout [ShellCommandLine.Command]) {
        if peek() == "&" { index += 1 }
        index += 1
        if peek() == "(" {
            index += 1
            commands += parse(until: ")")
            return
        }
        if peek() == ">" || peek() == "|" { index += 1 }
        var duplicates = false
        if peek() == "&" {
            index += 1
            duplicates = true
        }
        skipBlanks()
        guard let target = readWord(into: &commands) else { return }
        if duplicates, target == "-" || target.allSatisfy(\.isNumber) { return }
        current.redirects.append(target)
    }

    mutating func readHeredocStart(commands: inout [ShellCommandLine.Command]) {
        var stripsTabs = false
        if peek() == "-" {
            stripsTabs = true
            index += 1
        }
        skipBlanks()
        let start = index
        guard let delimiter = readWord(into: &commands) else { return }
        let quoted = characters[start..<min(index, characters.count)].contains { $0 == "'" || $0 == "\"" || $0 == "\\" }
        heredocs.append(Heredoc(delimiter: delimiter, expands: !quoted, stripsTabs: stripsTabs))
    }

    mutating func readHeredocBodies() -> [ShellCommandLine.Command] {
        var found: [ShellCommandLine.Command] = []
        let pending = heredocs
        heredocs = []
        for heredoc in pending {
            var body = ""
            while index < characters.count {
                let lineStart = index
                while let character = peek(), character != "\n" { index += 1 }
                var line = String(characters[lineStart..<index])
                if index < characters.count { index += 1 }
                if heredoc.stripsTabs { line = String(line.drop { $0 == "\t" }) }
                if line == heredoc.delimiter { break }
                body += line + "\n"
            }
            guard heredoc.expands else { continue }
            var parser = ShellParser(Array(body))
            var ignored = ""
            parser.readQuoted(into: &ignored, commands: &found, terminator: nil)
        }
        return found
    }

    mutating func readWord(into commands: inout [ShellCommandLine.Command]) -> String? {
        var word = ""
        var quoted = false
        while let character = peek(), !Self.operators.contains(character) {
            switch character {
            case "\\":
                if let next = peek(1), next != "\n" { word.append(next) }
                index += 2
            case "'":
                quoted = true
                index += 1
                while let inner = peek(), inner != "'" {
                    word.append(inner)
                    index += 1
                }
                index += 1
            case "\"":
                quoted = true
                index += 1
                readQuoted(into: &word, commands: &commands, terminator: "\"")
            case "`":
                index += 1
                commands += readBackticks()
                word += "`…`"
            case "$" where peek(1) == "(":
                index += 2
                commands += parse(until: ")")
                word += "$(…)"
            case "$" where peek(1) == "{":
                while let inner = peek() {
                    word.append(inner)
                    index += 1
                    if inner == "}" { break }
                }
            default:
                word.append(character)
                index += 1
            }
        }
        if word.isEmpty && !quoted { return nil }
        if !quoted, word.allSatisfy(\.isNumber), peek() == ">" || peek() == "<" { return nil }
        return word
    }

    mutating func readQuoted(into word: inout String, commands: inout [ShellCommandLine.Command], terminator: Character?) {
        while let character = peek() {
            if character == terminator {
                index += 1
                return
            }
            switch character {
            case "\\":
                if let next = peek(1) {
                    if !"\"\\$`\n".contains(next) { word.append(character) }
                    if next != "\n" { word.append(next) }
                }
                index += 2
            case "`":
                index += 1
                commands += readBackticks()
                word += "`…`"
            case "$" where peek(1) == "(":
                index += 2
                commands += parse(until: ")")
                word += "$(…)"
            default:
                word.append(character)
                index += 1
            }
        }
    }

    mutating func readBackticks() -> [ShellCommandLine.Command] {
        var inner = ""
        while let character = peek(), character != "`" {
            if character == "\\", let next = peek(1), "`\\$".contains(next) {
                inner.append(next)
                index += 2
                continue
            }
            inner.append(character)
            index += 1
        }
        index += 1
        return ShellCommandLine(inner).commands
    }
}
