import Foundation
import Synchronization

public enum ProjectFilesRoots {
    static let overrides = Mutex<[String: URL]>([:])

    public static func set(_ root: URL?, forProjectAt path: String) {
        overrides.withLock { $0[path] = root }
    }

    static func root(forProjectAt path: String) -> URL? {
        overrides.withLock { $0[path] }
    }
}

public enum ProjectConfigFiles {
    public static let folders = [ProjectConfig.directoryName, ".claude/skills", SkillPluginInstaller.settingsPath]
    public static let maximumTopLevelFileSize = 256 * 1024

    public static func collect(in repository: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: repository, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= maximumTopLevelFileSize,
                  let data = try? Data(contentsOf: entry) else { continue }
            files[entry.lastPathComponent] = data
        }
        for folder in folders {
            let base = repository.appending(path: folder)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                files[folder] = try? Data(contentsOf: base)
                continue
            }
            let enumerator = manager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: url) else { continue }
                let relative = folder + "/" + url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)
                files[relative] = data
            }
        }
        return files
    }
}

@MainActor
public struct DaemonFilesMirror {
    public let connection: DaemonConnection
    public let project: Project
    public let directory: URL

    public init(connection: DaemonConnection, project: Project, cacheRoot: URL) {
        self.connection = connection
        self.project = project
        self.directory = cacheRoot.appending(path: "projects/\(project.id ?? -1)/files", directoryHint: .isDirectory)
    }

    var manifestURL: URL { directory.deletingLastPathComponent().appending(path: "manifest.json") }

    public func activate() {
        ProjectFilesRoots.set(directory, forProjectAt: project.path)
    }

    public func pull() async throws {
        guard let id = project.id else { return }
        try await push()
        let files = try await connection.send(ProjectCommands.ConfigFiles(projectID: id))
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = directory.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        try saveManifest(files.mapValues(SHA256Digest.hex(of:)))
        activate()
    }

    @discardableResult
    public func push() async throws -> [String] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let manifest = loadManifest()
        let local = ProjectConfigFiles.collect(in: directory)
        var changed: [String] = []
        for (path, data) in local where manifest[path] != SHA256Digest.hex(of: data) {
            _ = try await connection.send(CodeCommands.WriteFile(path: project.url.appending(path: path).path, data: data))
            changed.append(path)
        }
        for path in manifest.keys where local[path] == nil {
            _ = try await connection.send(CodeCommands.RemoveItem(path: project.url.appending(path: path).path))
            changed.append(path)
        }
        if !changed.isEmpty { try saveManifest(local.mapValues(SHA256Digest.hex(of:))) }
        return changed
    }

    func loadManifest() -> [String: String] {
        (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func saveManifest(_ manifest: [String: String]) throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
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
        ProjectFilesRoots.root(forProjectAt: path) ?? url
    }
}
