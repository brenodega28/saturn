import Foundation

public struct ToolLocator: Sendable {
    public let searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        self.searchDirectories = searchDirectories
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let wellKnown = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let inHome = [
            ".local/bin",
            ".claude/local",
            ".npm-global/bin",
            ".volta/bin",
            ".bun/bin",
        ].map { homeDirectory.appending(path: $0, directoryHint: .isDirectory) }

        var seen = Set<String>()
        self.searchDirectories = (fromPath + wellKnown + inHome).filter { seen.insert($0.path).inserted }
    }

    public var searchPath: String {
        searchDirectories.map(\.path).joined(separator: ":")
    }

    public func locate(_ name: String) -> URL? {
        searchDirectories
            .map { $0.appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func environment(merging base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["PATH"] = searchPath
        return environment
    }
}
