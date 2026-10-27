import Foundation

public struct CheckSuggestions: Sendable, Hashable {
    public var checks: [CheckDefinition]
    public var protectedPaths: [String]
    public var evidence: [String]

    public init(checks: [CheckDefinition], protectedPaths: [String], evidence: [String]) {
        self.checks = checks
        self.protectedPaths = protectedPaths
        self.evidence = evidence
    }

    public var config: ChecksConfig {
        ChecksConfig(checks: checks, protectedPaths: protectedPaths)
    }

    public var hasTestCheck: Bool {
        checks.contains { $0.kind == .test }
    }
}

public enum CheckDetector {
    static let skippedDirectories: Set<String> = [".git", ".crew", "node_modules", ".build", "build", "dist", "vendor", "target", ".venv", "venv", "DerivedData", "Pods"]
    static let scanLimit = 4000

    public static func suggest(repository: URL) -> CheckSuggestions {
        let files = listFiles(in: repository)
        let names = Set(files)
        var suggestions = CheckSuggestions(checks: [], protectedPaths: [], evidence: [])

        func add(_ name: String, _ kind: CheckKind, _ command: String, onEdit: Bool = false, because evidence: String) {
            guard !suggestions.checks.contains(where: { $0.kind == kind }) else { return }
            suggestions.checks.append(CheckDefinition(name: name, kind: kind, command: command, onEdit: onEdit))
            if !suggestions.evidence.contains(evidence) { suggestions.evidence.append(evidence) }
        }

        if names.contains("package.json"), let scripts = packageScripts(repository.appending(path: "package.json")) {
            let runner = names.contains("pnpm-lock.yaml") ? "pnpm" : names.contains("yarn.lock") ? "yarn" : names.contains("bun.lockb") || names.contains("bun.lock") ? "bun run" : "npm run"
            let run = { (script: String) in runner + " " + script }
            if let script = ["format:check", "fmt:check", "prettier:check", "check-format"].first(where: scripts.contains) {
                add("format", .format, run(script), onEdit: true, because: "package.json script “\(script)”")
            }
            if scripts.contains("lint") { add("lint", .lint, run("lint"), because: "package.json script “lint”") }
            if let script = ["typecheck", "type-check", "tsc", "check-types"].first(where: scripts.contains) {
                add("typecheck", .typecheck, run(script), because: "package.json script “\(script)”")
            } else if names.contains("tsconfig.json") {
                add("typecheck", .typecheck, "npx tsc --noEmit", because: "tsconfig.json")
            }
            if scripts.contains("test") {
                add("test", .test, runner == "npm run" ? "npm test" : run("test"), because: "package.json script “test”")
            }
        }

        let pythonMarkers = ["pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini", "conftest.py", "setup.py"]
        if let marker = pythonMarkers.first(where: names.contains) {
            let pyproject = (try? String(contentsOf: repository.appending(path: "pyproject.toml"), encoding: .utf8)) ?? ""
            let prefix = names.contains("uv.lock") ? "uv run " : names.contains("poetry.lock") ? "poetry run " : ""
            let usesRuff = pyproject.contains("[tool.ruff") || names.contains("ruff.toml") || names.contains(".ruff.toml")
            if usesRuff {
                add("format", .format, prefix + "ruff format --check .", onEdit: true, because: "ruff configuration")
                add("lint", .lint, prefix + "ruff check .", because: "ruff configuration")
            }
            if pyproject.contains("[tool.mypy") || names.contains("mypy.ini") {
                add("typecheck", .typecheck, prefix + "mypy .", because: "mypy configuration")
            }
            let hasTests = names.contains("conftest.py") || files.contains { file in
                let name = file.split(separator: "/").last.map(String.init) ?? file
                return (name.hasPrefix("test_") && name.hasSuffix(".py")) || name.hasSuffix("_test.py")
            }
            if hasTests || pyproject.contains("pytest") || names.contains("pytest.ini") {
                add("test", .test, prefix.isEmpty ? "python3 -m pytest -q" : prefix + "pytest -q", because: marker)
            }
        }

        if names.contains("Cargo.toml") {
            add("format", .format, "cargo fmt --check", onEdit: true, because: "Cargo.toml")
            add("lint", .lint, "cargo clippy -- -D warnings", because: "Cargo.toml")
            add("test", .test, "cargo test", because: "Cargo.toml")
        }
        if names.contains("go.mod") {
            add("format", .format, "test -z \"$(gofmt -l .)\"", onEdit: true, because: "go.mod")
            add("lint", .lint, "go vet ./...", because: "go.mod")
            add("test", .test, "go test ./...", because: "go.mod")
        }
        if names.contains("Package.swift") {
            add("build", .typecheck, "swift build", because: "Package.swift")
            add("test", .test, "swift test", because: "Package.swift")
        }
        if names.contains("mix.exs") {
            add("format", .format, "mix format --check-formatted", onEdit: true, because: "mix.exs")
            add("test", .test, "mix test", because: "mix.exs")
        }
        if names.contains("Gemfile"), files.contains(where: { $0.hasSuffix("_spec.rb") }) {
            add("test", .test, "bundle exec rspec", because: "Gemfile and *_spec.rb files")
        }
        if let targets = makeTargets(repository.appending(path: "Makefile")) {
            if targets.contains("lint") { add("lint", .lint, "make lint", because: "Makefile target “lint”") }
            if targets.contains("test") { add("test", .test, "make test", because: "Makefile target “test”") }
        }

        suggestions.protectedPaths = protectedPaths(in: files)
        return suggestions
    }

    static func protectedPaths(in files: [String]) -> [String] {
        let directories = Set(files.compactMap { $0.split(separator: "/").first.map(String.init) })
        var paths = ["tests", "test", "spec", "__tests__"].filter(directories.contains).map { "\($0)/**" }
        let rules: [(String, (String) -> Bool)] = [
            ("**/__tests__/**", { $0.contains("/__tests__/") }),
            ("*_test.go", { $0.hasSuffix("_test.go") }),
            ("test_*.py", { ($0.split(separator: "/").last ?? "").hasPrefix("test_") && $0.hasSuffix(".py") }),
            ("*_test.py", { $0.hasSuffix("_test.py") }),
            ("*.test.*", { ($0.split(separator: "/").last ?? "").contains(".test.") }),
            ("*.spec.*", { ($0.split(separator: "/").last ?? "").contains(".spec.") }),
            ("*_spec.rb", { $0.hasSuffix("_spec.rb") }),
            ("*Tests.swift", { $0.hasSuffix("Tests.swift") }),
        ]
        for (pattern, matches) in rules where files.contains(where: matches) {
            let covered = files.filter(matches).allSatisfy { file in paths.contains { PathGlob($0).matches(file) } }
            if !covered { paths.append(pattern) }
        }
        return paths
    }

    static func listFiles(in repository: URL) -> [String] {
        let root = repository.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: repository, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            if files.count >= scanLimit { break }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedDirectories.contains(name) || (name.hasPrefix(".") && name != ".github") { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            files.append(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : name)
        }
        return files
    }

    static func packageScripts(_ file: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: file), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        guard case .object(let scripts)? = json["scripts"] else { return [] }
        return Set(scripts.keys)
    }

    static func makeTargets(_ file: URL) -> Set<String>? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(" ") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name.contains(" ") || name.hasPrefix(".") ? nil : name
        })
    }
}
