import Foundation

public struct AgentMemory: Sendable, Hashable {
    public static let directoryName = "memory"
    public static let gitIgnoreEntries = ["memory/", "local.yaml"]
    public static let maximumLines = 60
    public static let promptCharacterLimit = 6_000

    public let repository: URL
    public let agentName: String

    public init(repository: URL, agentName: String) {
        self.repository = repository
        self.agentName = agentName
    }

    public static func directory(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: directoryName, directoryHint: .isDirectory)
    }

    public var slug: String {
        let slug = Slug.make(agentName)
        return slug.isEmpty ? "agent" : slug
    }

    public var url: URL {
        Self.directory(in: repository).appending(path: "\(slug).md")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func write(_ text: String) throws {
        try prepareDirectory()
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data((normalized.isEmpty ? "" : normalized + "\n").utf8).write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: url)
    }

    @discardableResult
    public func prepareDirectory() throws -> URL {
        let directory = Self.directory(in: repository)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.ensureGitIgnore(in: repository)
        return directory
    }

    public var notes: [String] { Self.notes(in: read()) }

    public var noteCount: Int { notes.count }

    public var estimatedTokens: Int { Self.estimatedTokens(in: read()) }

    public func forgetNote(at index: Int) throws {
        let text = read()
        var lines = text.components(separatedBy: "\n")
        let bulletIndices = lines.indices.filter { Self.note(fromLine: lines[$0]) != nil }
        guard bulletIndices.indices.contains(index) else { return }
        lines.remove(at: bulletIndices[index])
        try write(lines.joined(separator: "\n"))
    }

    public func promptSection(characterLimit: Int = promptCharacterLimit) -> String? {
        let text = read().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let body = Self.truncated(text, characterLimit: characterLimit)
        return """
            ## Your memory
            Notes you kept from earlier runs in this project (from \(url.path)). Treat them as hints and check them against the code.

            \(body)
            """
    }

    public static func notes(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap(note(fromLine:))
    }

    public static func note(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let note = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return note.isEmpty ? nil : note
        }
        return nil
    }

    public static func estimatedTokens(in text: String) -> Int {
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return characters == 0 ? 0 : max(1, Int((Double(characters) / 4).rounded(.up)))
    }

    static func truncated(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        var kept: [String] = []
        var used = 0
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard used + line.count + 1 <= characterLimit else { break }
            kept.append(line)
            used += line.count + 1
        }
        let dropped = lines.count - kept.count
        return kept.joined(separator: "\n") + "\n\n(\(dropped) more line\(dropped == 1 ? "" : "s") cut to keep your context small.)"
    }

    public static func ensureGitIgnore(in repository: URL) throws {
        let directory = ProjectConfig.directory(in: repository)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: ".gitignore")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let present = Set(existing.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = gitIgnoreEntries.filter { !present.contains($0) && !present.contains("/" + $0) }
        guard !missing.isEmpty else { return }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += missing.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}
