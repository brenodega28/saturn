import Foundation

struct ScannedLine: Sendable, Hashable {
    let file: String
    let line: Int
    let text: String
}

struct ScannedDiff: Sendable {
    var added: [ScannedLine] = []
    var removed: [ScannedLine] = []

    static func parse(_ diff: String) -> ScannedDiff {
        var scanned = ScannedDiff()
        var file: String?
        var oldLine = 0
        var newLine = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                file = path == "/dev/null" ? nil : (path.hasPrefix("b/") ? String(path.dropFirst(2)) : path)
            } else if line.hasPrefix("--- ") {
                continue
            } else if line.hasPrefix("@@") {
                let parts = line.split(separator: " ")
                if parts.count > 2 {
                    oldLine = parts[1].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0
                    newLine = parts[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 0
                }
            } else if line.hasPrefix("+"), let file {
                scanned.added.append(ScannedLine(file: file, line: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-"), let file {
                scanned.removed.append(ScannedLine(file: file, line: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            }
        }
        return scanned
    }
}

enum SecretScanner {
    static let patterns: [(name: String, expression: NSRegularExpression)] = [
        ("an AWS access key", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("a private key", #"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY"#),
        ("a GitHub token", #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        ("an Anthropic API key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("an OpenAI API key", #"\bsk-(proj-)?[A-Za-z0-9]{32,}\b"#),
        ("a Stripe live key", #"\b(sk|rk)_live_[A-Za-z0-9]{20,}\b"#),
        ("a Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("a Google API key", #"\bAIza[0-9A-Za-z\-_]{35}\b"#),
        ("a hard-coded secret", #"(?i)\b(api[_-]?key|secret|password|passwd|access[_-]?token|auth[_-]?token)\b["']?\s*[:=]\s*["'][^"'\s$<{]{12,}["']"#),
    ].compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern)).map { (name, $0) } }

    static func scan(_ lines: [ScannedLine], agentName: String?) -> [GateFinding] {
        lines.compactMap { line in
            guard !GeneratedFiles.isGenerated(line.file), line.text.count < 2000 else { return nil }
            let range = NSRange(line.text.startIndex..., in: line.text)
            guard let match = patterns.first(where: { $0.expression.firstMatch(in: line.text, range: range) != nil }) else { return nil }
            return GateFinding(
                kind: .secret, severity: .blocking, title: "Possible secret: \(match.name)",
                detail: "An added line looks like it contains \(match.name). Move it to an environment variable or secret store, and rotate it if it’s real.",
                file: line.file, line: line.line, agentName: agentName
            )
        }
    }
}

enum ComplexityScanner {
    static let branch = try? NSRegularExpression(pattern: #"\b(if|elif|else if|for|foreach|while|case|catch|except|guard|switch|when)\b|&&|\|\||\?\?|\s\?\s"#)

    static func count(_ text: String) -> Int {
        guard let branch else { return 0 }
        return branch.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func scan(_ diff: ScannedDiff, limit: Int, agentName: String?) -> [GateFinding] {
        var growth: [String: Int] = [:]
        for line in diff.added where !GeneratedFiles.isGenerated(line.file) { growth[line.file, default: 0] += count(line.text) }
        for line in diff.removed where !GeneratedFiles.isGenerated(line.file) { growth[line.file, default: 0] -= count(line.text) }
        return growth.filter { $0.value > limit }.sorted { $0.key < $1.key }.map { file, added in
            GateFinding(
                kind: .complexity, severity: .warning, title: "Complexity grew by \(added) branches",
                detail: "This change adds \(added) decision points to \(file), more than the limit of \(limit). Consider splitting the logic into smaller functions.",
                file: file, agentName: agentName
            )
        }
    }
}

enum DuplicationScanner {
    static let window = 6

    static func normalize(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4, !["//", "#", "/*", "*", "--"].contains(where: trimmed.hasPrefix) else { return nil }
        return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func windows(_ lines: [(number: Int, text: String)]) -> [(key: String, numbers: [Int])] {
        let meaningful = lines.compactMap { line in normalize(line.text).map { (line.number, $0) } }
        guard meaningful.count >= window else { return [] }
        return (0...(meaningful.count - window)).map { start in
            let slice = meaningful[start..<(start + window)]
            return (slice.map(\.1).joined(separator: "\n"), slice.map(\.0))
        }
    }

    static let maximumFileBytes = 300_000

    static func candidates(_ diff: ScannedDiff, trackedFiles: [String]) -> [String] {
        let extensions = Set(diff.added.filter { !GeneratedFiles.isGenerated($0.file) }.map { ($0.file as NSString).pathExtension.lowercased() }.filter { !$0.isEmpty })
        return trackedFiles.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) && !GeneratedFiles.isGenerated($0) }
    }

    static func scan(_ diff: ScannedDiff, worktree: URL, trackedFiles: [String], limit: Int, agentName: String?, contents: [String: String]? = nil) -> [GateFinding] {
        let addedByFile = Dictionary(grouping: diff.added.filter { !GeneratedFiles.isGenerated($0.file) }, by: \.file)
        guard !addedByFile.isEmpty else { return [] }
        var existing: Set<String> = []
        for path in candidates(diff, trackedFiles: trackedFiles) {
            let url = worktree.appending(path: path)
            let text: String
            if let contents {
                guard let fetched = contents[path] else { continue }
                text = fetched
            } else {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), (attributes[.size] as? Int ?? 0) < maximumFileBytes,
                      let local = try? String(contentsOf: url, encoding: .utf8) else { continue }
                text = local
            }
            let addedNumbers = Set(addedByFile[path]?.map(\.line) ?? [])
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { (number: $0.offset + 1, text: String($0.element)) }
            for entry in windows(lines) where Set(entry.numbers).isDisjoint(with: addedNumbers) {
                existing.insert(entry.key)
            }
        }

        var addedCounts: [String: Int] = [:]
        var addedWindows: [(file: String, key: String, numbers: [Int])] = []
        for (file, lines) in addedByFile {
            for block in contiguousBlocks(lines) {
                for entry in windows(block.map { (number: $0.line, text: $0.text) }) {
                    addedWindows.append((file, entry.key, entry.numbers))
                    addedCounts[entry.key, default: 0] += 1
                }
            }
        }
        var duplicated: [String: Set<Int>] = [:]
        for entry in addedWindows where existing.contains(entry.key) || (addedCounts[entry.key] ?? 0) > 1 {
            duplicated[entry.file, default: []].formUnion(entry.numbers)
        }
        let total = duplicated.values.reduce(0) { $0 + $1.count }
        guard total > limit else { return [] }
        return duplicated.sorted { $0.key < $1.key }.map { file, numbers in
            GateFinding(
                kind: .duplication, severity: .warning, title: "\(numbers.count) duplicated lines",
                detail: "Added code in \(file) repeats code that already exists (\(total) duplicated lines in this change, limit \(limit)). Reuse or extract the shared logic instead of copying it.",
                file: file, line: numbers.min(), agentName: agentName
            )
        }
    }

    static func contiguousBlocks(_ lines: [ScannedLine]) -> [[ScannedLine]] {
        var blocks: [[ScannedLine]] = []
        for line in lines.sorted(by: { $0.line < $1.line }) {
            if let last = blocks.last?.last, last.line + 1 == line.line {
                blocks[blocks.count - 1].append(line)
            } else {
                blocks.append([line])
            }
        }
        return blocks
    }
}

public enum PackageEcosystem: String, Sendable, Hashable, Codable {
    case npm
    case pypi
    case crates
    case go

    public var registryName: String {
        switch self {
        case .npm: "npm"
        case .pypi: "PyPI"
        case .crates: "crates.io"
        case .go: "the Go module proxy"
        }
    }
}

public struct NewDependency: Sendable, Hashable {
    public let name: String
    public let ecosystem: PackageEcosystem
    public let file: String
}

public protocol PackageRegistry: Sendable {
    func exists(_ name: String, in ecosystem: PackageEcosystem) async -> Bool?
}

public struct PublicPackageRegistry: PackageRegistry {
    public init() {}

    public func exists(_ name: String, in ecosystem: PackageEcosystem) async -> Bool? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let address = switch ecosystem {
        case .npm: "https://registry.npmjs.org/\(encoded.replacingOccurrences(of: "/", with: "%2F"))"
        case .pypi: "https://pypi.org/pypi/\(encoded)/json"
        case .crates: "https://crates.io/api/v1/crates/\(encoded)"
        case .go: "https://proxy.golang.org/\(encoded.lowercased())/@v/list"
        }
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = ecosystem == .crates ? "GET" : "HEAD"
        request.setValue("Ensemble (dependency check)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.statusCode == 410 { return false }
        return (200..<300).contains(http.statusCode) ? true : nil
    }
}

enum DependencyScanner {
    static let manifests = ["package.json", "requirements.txt", "requirements-dev.txt", "pyproject.toml", "Cargo.toml", "go.mod"]

    static func isManifest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return manifests.contains(name) || (name.hasPrefix("requirements") && name.hasSuffix(".txt"))
    }

    static func newDependencies(file: String, base: String?, head: String) -> [NewDependency] {
        let name = (file as NSString).lastPathComponent
        let ecosystem: PackageEcosystem
        let names: (String) -> Set<String>
        switch name {
        case "package.json":
            ecosystem = .npm
            names = npmDependencies
        case "Cargo.toml":
            ecosystem = .crates
            names = cargoDependencies
        case "go.mod":
            ecosystem = .go
            names = goDependencies
        case "pyproject.toml":
            ecosystem = .pypi
            names = pyprojectDependencies
        default:
            ecosystem = .pypi
            names = requirementNames
        }
        let added = names(head).subtracting(base.map(names) ?? [])
        return added.sorted().map { NewDependency(name: $0, ecosystem: ecosystem, file: file) }
    }

    static func npmDependencies(_ text: String) -> Set<String> {
        guard let json = JSONValue.parse(text) else { return [] }
        var names: Set<String> = []
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            if case .object(let entries)? = json[key] { names.formUnion(entries.keys) }
        }
        return names
    }

    static func requirementNames(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-") else { return nil }
            return packageName(trimmed)
        })
    }

    static func pyprojectDependencies(_ text: String) -> Set<String> {
        var names: Set<String> = []
        var inArray = false
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("dependencies") && line.contains("[") { inArray = true }
            if inArray {
                for quoted in line.split(separator: "\"", omittingEmptySubsequences: false).enumerated() where quoted.offset % 2 == 1 {
                    if let name = packageName(String(quoted.element)) { names.insert(name) }
                }
                if line.contains("]") { inArray = false }
            }
        }
        return names
    }

    static func packageName(_ requirement: String) -> String? {
        let name = requirement.prefix { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        return name.isEmpty ? nil : name.lowercased()
    }

    static func cargoDependencies(_ text: String) -> Set<String> {
        var names: Set<String> = []
        var inSection = false
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                inSection = ["[dependencies]", "[dev-dependencies]", "[build-dependencies]"].contains(line)
                continue
            }
            guard inSection, let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    static func goDependencies(_ text: String) -> Set<String> {
        var names: Set<String> = []
        var inBlock = false
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("require (") { inBlock = true; continue }
            if inBlock && line == ")" { inBlock = false; continue }
            let entry = inBlock ? line : (line.hasPrefix("require ") ? String(line.dropFirst(8)) : "")
            if let module = entry.split(separator: " ").first, module.contains("."), !entry.contains("// indirect") {
                names.insert(String(module))
            }
        }
        return names
    }
}
