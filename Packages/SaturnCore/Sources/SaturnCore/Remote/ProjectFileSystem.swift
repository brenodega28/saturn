import Foundation

public protocol ProjectFileSystem: Sendable {
    var isLocal: Bool { get }
    func fileExists(_ url: URL) async throws -> Bool
    func createDirectory(_ url: URL) async throws
    func readText(_ url: URL) async throws -> String?
    func readData(_ url: URL) async throws -> Data?
    func writeData(_ data: Data, to url: URL) async throws
    func writeText(_ text: String, to url: URL) async throws
    func subdirectories(of url: URL) async throws -> [URL]
    func removeItem(_ url: URL) async throws
    func canonicalPath(_ url: URL) -> String
}

public struct LocalFileSystem: ProjectFileSystem {
    public init() {}

    public var isLocal: Bool { true }

    public func fileExists(_ url: URL) async throws -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func createDirectory(_ url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func readText(_ url: URL) async throws -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    public func writeText(_ text: String, to url: URL) async throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func readData(_ url: URL) async throws -> Data? {
        try? Data(contentsOf: url)
    }

    public func writeData(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .atomic)
    }

    public func subdirectories(of url: URL) async throws -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    public func removeItem(_ url: URL) async throws {
        try FileManager.default.removeItem(at: url)
    }

    public func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        return Self.trimmingTrailingSlashes(path)
    }

    static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

public struct SSHFileSystem: ProjectFileSystem {
    public let client: SSHClient

    public init(client: SSHClient) {
        self.client = client
    }

    public var isLocal: Bool { false }

    public func fileExists(_ url: URL) async throws -> Bool {
        try await client.run(arguments: ["test", "-e", url.path]).succeeded
    }

    public func createDirectory(_ url: URL) async throws {
        _ = try await client.runChecked(arguments: ["mkdir", "-p", "--", url.path])
    }

    public func readText(_ url: URL) async throws -> String? {
        let result = try await client.run(arguments: ["cat", "--", url.path])
        return result.succeeded ? result.standardOutput : nil
    }

    public func writeText(_ text: String, to url: URL) async throws {
        let script = #"printf '%s' "$1" > "$2.saturn-tmp" && mv -f -- "$2.saturn-tmp" "$2""#
        _ = try await client.runChecked(arguments: ["sh", "-c", script, "saturn", text, url.path])
    }

    public func readData(_ url: URL) async throws -> Data? {
        let result = try await client.run(arguments: ["sh", "-c", #"[ -f "$1" ] || exit 4; base64 < "$1""#, "saturn", url.path])
        guard result.succeeded else { return nil }
        return Data(base64Encoded: result.standardOutput, options: .ignoreUnknownCharacters)
    }

    public func writeData(_ data: Data, to url: URL) async throws {
        let script = #"""
        printf '%s' "$2" > "$1.saturn-b64"
        { base64 -d < "$1.saturn-b64" 2>/dev/null || base64 -D < "$1.saturn-b64"; } > "$1.saturn-tmp" && mv -f -- "$1.saturn-tmp" "$1"
        status=$?; rm -f -- "$1.saturn-b64" "$1.saturn-tmp"; exit $status
        """#
        _ = try await client.runChecked(arguments: ["sh", "-c", script, "saturn", url.path, data.base64EncodedString()])
    }

    public func subdirectories(of url: URL) async throws -> [URL] {
        do {
            let listing = try await RemoteHost(client: client).list(url.path)
            return listing.entries
                .filter { !$0.name.hasPrefix(".") }
                .map { URL(fileURLWithPath: listing.path, isDirectory: true).appending(path: $0.name, directoryHint: .isDirectory) }
        } catch RemoteFolderError.notFound {
            return []
        }
    }

    public func removeItem(_ url: URL) async throws {
        _ = try await client.runChecked(arguments: ["rm", "-rf", "--", url.path])
    }

    public func canonicalPath(_ url: URL) -> String {
        Self.normalize(url.path)
    }

    public func readTextFiles(in root: URL, paths: [String], maximumBytes: Int) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let script = #"""
        cd -- "$1" 2>/dev/null || exit 3; max=$2; shift 2
        for f in "$@"; do
          [ -f "./$f" ] || continue
          [ "$(wc -c < "./$f" | tr -d ' ')" -lt "$max" ] || continue
          printf '%s\0' "$f"; base64 < "./$f" | tr -d '\n'; printf '\0'
        done
        """#
        var contents: [String: String] = [:]
        for batch in stride(from: 0, to: paths.count, by: 500).map({ Array(paths[$0..<min($0 + 500, paths.count)]) }) {
            guard let result = try? await client.run(arguments: ["sh", "-c", script, "saturn", root.path, String(maximumBytes)] + batch),
                  result.succeeded else { continue }
            let fields = RemoteHost.records(result.standardOutput)
            for index in stride(from: 0, to: fields.count - 1, by: 2) {
                if let data = Data(base64Encoded: fields[index + 1]), let text = String(data: data, encoding: .utf8) {
                    contents[fields[index]] = text
                }
            }
        }
        return contents
    }

    static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
