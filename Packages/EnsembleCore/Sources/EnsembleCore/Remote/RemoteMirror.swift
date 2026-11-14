import CryptoKit
import Foundation
import Synchronization

public struct RemoteMirrorConflict: Error, LocalizedError, Equatable {
    public let paths: [String]

    public var errorDescription: String? {
        "These files changed on the host since Ensemble last read them, so your edits to them weren’t sent: \(paths.joined(separator: ", ")). Ensemble reloaded the host’s versions."
    }
}

public struct RemoteMirrorChanges: Equatable, Sendable {
    public var written: [String] = []
    public var deleted: [String] = []

    public var isEmpty: Bool { written.isEmpty && deleted.isEmpty }
    public var all: [String] { (written + deleted).sorted() }
}

public struct RemoteMirror: Sendable {
    public static let maximumTopLevelFileSize = 256 * 1024
    public static let pulledFolders = [ProjectConfig.directoryName, ".claude/skills", SkillPluginInstaller.settingsPath]
    static let absentHash = "-"

    public let directory: URL
    public let manifestFile: URL
    public let repository: String
    let client: SSHClient

    public init(directory: URL, manifestFile: URL, repository: String, client: SSHClient) {
        self.directory = directory
        self.manifestFile = manifestFile
        self.repository = repository
        self.client = client
    }

    static let rootOverrides = Mutex<[String: URL]>([:])

    public static func location(forProject id: Int64, host: String? = nil, paths: AppPaths = .standard) -> (directory: URL, manifest: URL) {
        let base = host.flatMap { host in rootOverrides.withLock { $0[host] } } ?? paths.root
        let root = base.appending(path: "remote/\(id)", directoryHint: .isDirectory)
        return (root.appending(path: "files", directoryHint: .isDirectory), root.appending(path: "manifest.json"))
    }

    public func pull() async throws {
        let staging = directory.deletingLastPathComponent().appending(path: "pull-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try await fetch(Self.pulledFolders, includingTopLevelFiles: true, into: staging)
        let config = ProjectConfigLoader.load(repository: staging)
        let referenced = [config.specs.folder] + config.docs.docs.compactMap(\.path)
        let missing = referenced.filter { !FileManager.default.fileExists(atPath: staging.appending(path: $0).path) }
        if !missing.isEmpty {
            try await fetch(missing, includingTopLevelFiles: false, into: staging)
        }

        let manager = FileManager.default
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
        try manager.moveItem(at: staging, to: directory)
        try saveManifest(Self.hashes(in: directory))
    }

    public func pendingChanges() throws -> RemoteMirrorChanges {
        let base = loadManifest()
        let current = Self.hashes(in: directory)
        var changes = RemoteMirrorChanges()
        changes.written = current.filter { base[$0.key] != $0.value }.map(\.key).sorted()
        changes.deleted = base.keys.filter { current[$0] == nil }.sorted()
        return changes
    }

    @discardableResult
    public func push() async throws -> RemoteMirrorChanges {
        let changes = try pendingChanges()
        guard !changes.isEmpty else { return changes }
        var manifest = loadManifest()
        let onHost = try await hostHashes(changes.all)
        let conflicts = changes.all.filter { (onHost[$0] ?? Self.absentHash) != (manifest[$0] ?? Self.absentHash) }
        guard conflicts.isEmpty else { throw RemoteMirrorConflict(paths: conflicts) }

        for path in changes.written {
            let data = try Data(contentsOf: directory.appending(path: path))
            try await write(data, to: path)
            manifest[path] = Self.hash(data)
        }
        for path in changes.deleted {
            _ = try await client.runChecked(arguments: ["rm", "-f", "--", path], in: repository)
            manifest[path] = nil
        }
        try saveManifest(manifest)
        return changes
    }

    func fetch(_ paths: [String], includingTopLevelFiles: Bool, into staging: URL) async throws {
        let script = #"""
        repo=$1; top=$2; shift 2; cd -- "$repo" 2>/dev/null || exit 3
        n=$#
        for p in "$@"; do [ -e "./$p" ] && set -- "$@" "./$p"; done
        shift $n
        if [ "$top" = 1 ]; then
          for f in * .[!.]* ..?*; do
            [ -f "$f" ] && [ ! -L "$f" ] && [ "$(wc -c < "$f")" -le \#(Self.maximumTopLevelFileSize) ] && set -- "$@" "./$f"
          done
        fi
        [ $# -eq 0 ] && exit 0
        tar -cf - "$@" | base64
        """#
        let result = try await client.run(arguments: ["sh", "-c", script, "ensemble", repository, includingTopLevelFiles ? "1" : "0"] + paths)
        if result.exitCode == RemoteHost.missingExitCode { throw RemoteFolderError.notFound(repository) }
        guard result.succeeded else { throw CommandError(command: "tar", result: result) }
        let encoded = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else { return }
        guard let archive = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { throw RemoteFolderError.unexpectedOutput }
        let file = staging.deletingLastPathComponent().appending(path: "\(UUID().uuidString).tar")
        try archive.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await CommandRunner().runChecked(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", file.path, "-C", staging.path])
    }

    func hostHashes(_ paths: [String]) async throws -> [String: String] {
        let script = #"""
        cd -- "$1" 2>/dev/null || exit 3; shift
        for f in "$@"; do
          if [ -f "./$f" ]; then (sha256sum "./$f" 2>/dev/null || shasum -a 256 "./$f") | cut -d' ' -f1; else echo -; fi
        done
        """#
        let result = try await client.runChecked(arguments: ["sh", "-c", script, "ensemble", repository] + paths)
        let lines = result.standardOutput.split(separator: "\n").map(String.init)
        guard lines.count == paths.count else { throw RemoteFolderError.unexpectedOutput }
        return Dictionary(uniqueKeysWithValues: zip(paths, lines))
    }

    func write(_ data: Data, to path: String) async throws {
        let script = #"""
        cd -- "$1" || exit 3
        mkdir -p -- "$(dirname -- "./$2")"
        printf '%s' "$3" > "./$2.ensemble-b64"
        { base64 -d < "./$2.ensemble-b64" 2>/dev/null || base64 -D < "./$2.ensemble-b64"; } > "./$2.ensemble-tmp" && mv -f -- "./$2.ensemble-tmp" "./$2"
        status=$?; rm -f -- "./$2.ensemble-b64" "./$2.ensemble-tmp"; exit $status
        """#
        _ = try await client.runChecked(arguments: ["sh", "-c", script, "ensemble", repository, path, data.base64EncodedString()])
    }

    func loadManifest() -> [String: String] {
        guard let data = try? Data(contentsOf: manifestFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func saveManifest(_ manifest: [String: String]) throws {
        try JSONEncoder().encode(manifest).write(to: manifestFile, options: .atomic)
    }

    static func hashes(in directory: URL) -> [String: String] {
        let root = directory.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var hashes: [String: String] = [:]
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: file) else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            hashes[String(path.dropFirst(root.count))] = hash(data)
        }
        return hashes
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Project {
    public var sshClient: SSHClient? {
        host.map { destination in
            let override = SSHClient.executable(for: destination)
            return SSHClient(destination: destination, executable: override ?? SSHClient.defaultExecutable, controlDirectory: override == nil ? SSHClient.sharedControlDirectory() : nil)
        }
    }

    public var fileSystem: any ProjectFileSystem {
        sshClient.map { SSHFileSystem(client: $0) } ?? LocalFileSystem()
    }

    public var filesRoot: URL {
        guard isRemote, let id else { return url }
        return RemoteMirror.location(forProject: id, host: host).directory
    }
}
