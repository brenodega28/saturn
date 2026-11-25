import Foundation

enum TempPaths {
    static let roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    static let tmpdir = "/tmp"
    static let globCharacters: Set<Character> = ["*", "?", "[", "{"]

    static func isTemp(_ path: String, variables: [String: String] = [:], cwd: String? = nil, excluding workspace: String? = nil) -> Bool {
        guard let path = resolved(path, variables: variables, cwd: cwd), isBelowRoot(path) else { return false }
        return workspace.map { !overlaps(path, standardized($0)) } ?? true
    }

    static func overlaps(_ path: String, _ directory: String) -> Bool {
        let path = withoutPrivate(path), directory = withoutPrivate(directory)
        return path == directory || path.hasPrefix(directory + "/") || directory.hasPrefix(path + "/")
    }

    static func withoutPrivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    static func resolved(_ path: String, variables: [String: String], cwd: String?) -> String? {
        guard let expanded = expanded(path, variables: variables), !expanded.isEmpty, !expanded.hasPrefix("~") else { return nil }
        if expanded.hasPrefix("/") { return standardized(expanded) }
        guard let cwd, isBelowRoot(cwd) else { return nil }
        return standardized(cwd + "/" + expanded)
    }

    static func isBelowRoot(_ path: String) -> Bool {
        roots.contains { root in
            guard path.hasPrefix(root + "/") else { return false }
            let first = path.dropFirst(root.count + 1).prefix { $0 != "/" }
            return !first.isEmpty && !first.contains(where: globCharacters.contains)
        }
    }

    static func standardized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func expanded(_ path: String, variables: [String: String]) -> String? {
        guard !path.contains("`") else { return nil }
        var result = ""
        var rest = Substring(path)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            rest = rest[rest.index(after: dollar)...]
            let braced = rest.first == "{"
            if braced { rest = rest.dropFirst() }
            let name = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "_" }
            guard let first = name.first, !first.isNumber else { return nil }
            rest = rest.dropFirst(name.count)
            if braced {
                guard rest.first == "}" else { return nil }
                rest = rest.dropFirst()
            }
            guard let value = variables[String(name)], isPlain(value) else { return nil }
            result += value
        }
        return result + rest
    }

    static func isPlain(_ value: String) -> Bool {
        !value.contains { $0.isWhitespace || globCharacters.contains($0) }
    }

    static func madeByMktemp(_ name: String) -> String {
        "\(tmpdir)/mktemp-\(name)"
    }
}

struct ShellContext {
    static let unconditional: Set<String> = ["", ";", "\n", "&"]
    static let backgrounded: Set<String> = ["|", "|&", "&"]
    static let continuing: Set<String> = ["&&", "|", "|&"]

    var variables = ["TMPDIR": TempPaths.tmpdir]
    var cwd: String?
    var receivesArguments = false
    var workspace: String?
    private var lastEnding = ""
    private var lastStatementEnding = ""
    private var madeTempPath = false
    private var trusted = true

    init(cwd: String? = nil) {
        self.cwd = cwd
    }

    func receivingArguments() -> ShellContext {
        var context = self
        context.receivesArguments = true
        return context
    }

    func isTemp(_ path: String) -> Bool {
        TempPaths.isTemp(path, variables: variables, cwd: cwd, excluding: workspace)
    }

    func holdsOnlyTemp(_ paths: [String]) -> Bool {
        !receivesArguments && !paths.isEmpty && paths.allSatisfy(isTemp)
    }

    mutating func record(_ command: ShellCommandLine.Command) {
        let afterMktemp = madeTempPath
        madeTempPath = makesTempPath(command.words)
        let unwrapped = ShellRisk.unwrapped(command.words)
        let program = unwrapped?.first
        let names = Self.namesSet(by: command.words)
        if Self.definesFunction(command) || Self.reshapesTheShell.contains(program ?? "") || names.contains("IFS") { trusted = false }
        if Self.setsAnyVariable(program, unwrapped ?? []) { variables = [:] }
        names.forEach { variables[$0] = nil }
        if !command.nested, let assignments = Self.assignments(command.words) {
            let lasting = Self.unconditional.contains(lastStatementEnding) && !Self.backgrounded.contains(command.ending)
            let substitutions = command.words.filter { $0.contains("$(…)") || $0.contains("`…`") }.count
            for (name, value) in assignments {
                variables[name] = lasting ? assignedValue(name, value, afterMktemp: afterMktemp && substitutions == 1) : nil
            }
        }
        trackDirectory(command, program: program, arguments: Array(unwrapped?.dropFirst() ?? []))
        lastEnding = command.ending
        if !command.nested { lastStatementEnding = command.ending }
        if !trusted {
            variables = [:]
            cwd = nil
        }
    }

    private mutating func trackDirectory(_ command: ShellCommandLine.Command, program: String?, arguments: [String]) {
        switch program {
        case "cd":
            let reliable = command.ending == "&&" && (Self.unconditional.contains(lastEnding) || lastEnding == "&&")
            cwd = reliable ? directory(after: arguments) : nil
        case "pushd", "popd":
            cwd = nil
        default:
            if !Self.continuing.contains(command.ending) { cwd = nil }
        }
    }

    private func assignedValue(_ name: String, _ value: String, afterMktemp: Bool) -> String? {
        for marker in ["$(…)", "`…`"] where afterMktemp && value.hasPrefix(marker) {
            return TempPaths.expanded(TempPaths.madeByMktemp(name) + value.dropFirst(marker.count), variables: variables)
        }
        return TempPaths.expanded(value, variables: variables)
    }

    private func directory(after arguments: [String]) -> String? {
        guard let target = ShellRisk.operands(arguments).first,
              let expanded = TempPaths.expanded(target, variables: variables),
              expanded.hasPrefix("/") || expanded.hasPrefix(".") else { return nil }
        return TempPaths.resolved(expanded, variables: [:], cwd: cwd)
    }

    static let reshapesTheShell: Set<String> = ["eval", "source", ".", "function", "alias", "trap"]
    static let variableSetters: Set<String> = ["read", "declare", "typeset", "local", "readonly", "unset", "getopts", "mapfile", "readarray", "let"]

    static func setsAnyVariable(_ program: String?, _ words: [String]) -> Bool {
        guard let program else { return false }
        return variableSetters.contains(program) || (program == "printf" && words.contains { $0.hasPrefix("-v") })
    }

    static func definesFunction(_ command: ShellCommandLine.Command) -> Bool {
        command.ending == "(" && command.words.count == 1
    }

    static func namesSet(by words: [String]) -> Set<String> {
        var names = Set<String>()
        for (index, word) in words.enumerated() {
            if let name = assignedName(word) { names.insert(name) }
            names.formUnion(defaultedNames(word))
            if ["for", "select"].contains(word), words.indices.contains(index + 1) { names.insert(words[index + 1]) }
        }
        return names
    }

    static func assignedName(_ word: String) -> String? {
        let name = word.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "_" }
        let rest = word.dropFirst(name.count)
        guard isName(name), rest.hasPrefix("=") || rest.hasPrefix("+=") || rest.hasPrefix("[") else { return nil }
        return String(name)
    }

    static func defaultedNames(_ word: String) -> [String] {
        word.components(separatedBy: "${").dropFirst().compactMap { part in
            let name = part.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "_" }
            let rest = part.dropFirst(name.count)
            return rest.hasPrefix("=") || rest.hasPrefix(":=") ? String(name) : nil
        }
    }

    private func makesTempPath(_ words: [String]) -> Bool {
        guard let words = ShellRisk.unwrapped(words), words.first.map(ShellRisk.basename) == "mktemp" else { return false }
        let arguments = Array(words.dropFirst())
        let directory = ShellRisk.flagValue(arguments, ["-p", "--tmpdir"])
        if let directory, !isTemp(directory + "/x") { return false }
        let inTempDirectory = arguments.contains("-t") || directory != nil
        return ShellRisk.operands(arguments, valued: ["-p", "--tmpdir", "--suffix"])
            .allSatisfy { inTempDirectory ? !$0.contains("/") : isTemp($0) }
    }

    static func assignments(_ words: [String]) -> [(String, String)]? {
        let candidates = words.first == "export" ? Array(words.dropFirst()) : words
        guard !candidates.isEmpty else { return nil }
        var found: [(String, String)] = []
        for word in candidates {
            guard let equals = word.firstIndex(of: "="), isName(word[..<equals]) else { return nil }
            found.append((String(word[..<equals]), String(word[word.index(after: equals)...])))
        }
        return found
    }

    static func isName(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "_" }
    }
}

extension ShellRisk {
    static func changedPaths(_ program: String, _ arguments: [String]) -> [String]? {
        switch program {
        case "rm", "rmdir", "unlink", "tee":
            return operands(arguments)
        case "mkdir":
            return operands(arguments, valued: ["-m", "--mode"])
        case "touch":
            return operands(arguments, valued: ["-t", "-d", "-r", "-A"])
        case "chmod":
            return modePaths(arguments)
        case "chown", "chgrp":
            return Array(operands(arguments).dropFirst())
        case "cp", "ln":
            return destination(arguments)
        case "mv":
            return movedPaths(arguments)
        case "sed", "gsed":
            return inPlace(arguments) ? sedFiles(arguments) : nil
        case "perl":
            return inPlace(arguments) ? perlFiles(arguments) : nil
        case "tar":
            return tarPaths(arguments)
        case "unzip":
            return [flagValue(arguments, ["-d"]) ?? "."]
        default:
            return nil
        }
    }

    static func gitTargets(_ sub: String, _ arguments: [String], directory: String?) -> [String]? {
        guard ["init", "clone"].contains(sub), !arguments.contains(where: { $0.hasPrefix("--separate-git-dir") }) else { return nil }
        let valued: Set<String> = [
            "--template", "-b", "--branch", "--initial-branch", "--object-format", "-o", "--origin", "--depth", "-c", "--config",
            "--reference", "--reference-if-able", "-u", "--upload-pack", "-j", "--jobs", "--filter", "--shallow-since", "--shallow-exclude",
        ]
        let paths = operands(arguments, valued: valued)
        let target = (sub == "init" ? paths.first : paths.dropFirst().first) ?? "."
        guard let directory, !target.hasPrefix("/") else { return [target] }
        return [directory + "/" + target]
    }

    static func operands(_ arguments: [String], valued: Set<String> = []) -> [String] {
        var found: [String] = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word == "--" { return found + arguments[index...] }
            if valued.contains(word) { index += 1 } else if !word.hasPrefix("-") || word == "-" { found.append(word) }
        }
        return found
    }

    static func flagValue(_ arguments: [String], _ flags: Set<String>) -> String? {
        for (index, word) in arguments.enumerated() {
            if flags.contains(word) { return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil }
            if let flag = flags.first(where: { word.hasPrefix($0 + "=") }) { return String(word.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    static func modePaths(_ arguments: [String]) -> [String] {
        let modeIsFlag = arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains { !"RfvhHLPc".contains($0) } }
        let paths = operands(arguments)
        return modeIsFlag ? paths : Array(paths.dropFirst())
    }

    static func destination(_ arguments: [String]) -> [String] {
        if let target = flagValue(arguments, ["-t", "--target-directory"]) { return [target] }
        let paths = operands(arguments, valued: ["-S", "--suffix"])
        return paths.count > 1 ? [paths[paths.count - 1]] : []
    }

    static func movedPaths(_ arguments: [String]) -> [String] {
        let paths = operands(arguments, valued: ["-t", "--target-directory", "-S", "--suffix"])
        if let target = flagValue(arguments, ["-t", "--target-directory"]) { return paths + [target] }
        return paths.count > 1 ? paths : []
    }

    static func inPlace(_ arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("--in-place") || $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("i") }
    }

    static func sedFiles(_ arguments: [String]) -> [String] {
        let paths = operands(arguments, valued: ["-e", "-f", "--expression", "--file", "-l"]).filter { !$0.isEmpty }
        let hasScriptFlag = arguments.contains { ["-e", "-f", "--expression", "--file"].contains($0) || $0.hasPrefix("--expression=") }
        return hasScriptFlag ? paths : Array(paths.dropFirst())
    }

    static func perlFiles(_ arguments: [String]) -> [String] {
        var paths: [String] = []
        var hasScript = false
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word.hasPrefix("-"), !word.hasPrefix("--"), let last = word.last, "eE".contains(last) {
                hasScript = true
                index += 1
            } else if !word.hasPrefix("-") {
                paths.append(word)
            }
        }
        return hasScript ? paths : Array(paths.dropFirst())
    }

    static func tarPaths(_ arguments: [String]) -> [String]? {
        var mode: Character?
        var file: String?
        var directory: String?
        var unsafe = false
        var index = 0
        func value() -> String? {
            defer { index += 1 }
            return arguments.indices.contains(index) ? arguments[index] : nil
        }
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            switch word {
            case "-C", "--directory": directory = value()
            case "-f", "--file": file = value()
            case "--extract", "--get": mode = "x"
            case "--create": mode = "c"
            case "--absolute-names": unsafe = true
            case _ where word.hasPrefix("--directory="): directory = String(word.dropFirst("--directory=".count))
            case _ where word.hasPrefix("--file="): file = String(word.dropFirst("--file=".count))
            case _ where word.hasPrefix("--"): break
            case _ where word.hasPrefix("-") || index == 1:
                for letter in word.drop(while: { $0 == "-" }) {
                    if "xc".contains(letter) { mode = letter }
                    if letter == "P" { unsafe = true }
                    if letter == "f" { file = value() }
                }
            default: break
            }
        }
        guard let mode else { return nil }
        if unsafe { return [] }
        return [(mode == "x" ? directory : file) ?? "."]
    }
}
