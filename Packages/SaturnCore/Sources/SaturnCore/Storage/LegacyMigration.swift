import Darwin
import Foundation
import GRDB

public enum LegacyMigration {
    public enum Legacy {
        public static let appName = "Ensemble"
        public static let bundleID = "dev.monoliti.Ensemble"
        public static let daemonName = "ensembled"
        public static let daemonLabel = "dev.monoliti.ensembled"
        public static let keychainService = "dev.monoliti.Ensemble"
        public static let database = "ensemble.sqlite"
        public static let projectDirectory = ".ensemble"
        public static let dataDirectoryVariable = "ENSEMBLE_DATA_DIR"
        public static let urlScheme = "ensemble"
        public static let dataDirSuitePrefix = "dev.monoliti.Ensemble.data-dir."
        public static let homeDirectory = ".ensemble"
    }

    public static let doneKey = "legacyMigration.done"
    public static let bundleID = "dev.monoliti.Saturn"
    public static let keychainService = "dev.monoliti.Saturn"

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Saturn", directoryHint: .isDirectory)
    }

    static var legacyDefaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: Legacy.appName, directoryHint: .isDirectory)
    }

    public static var preferencesDirectory: URL {
        URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory)
    }

    public static func runIfNeeded(paths: [AppPaths], defaults: UserDefaults = AppDefaults.store, preferences: URL = preferencesDirectory) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let roots = paths.map(\.root.standardizedFileURL)
        if roots.contains(defaultRoot.standardizedFileURL) {
            removeLegacyLaunchAgent()
            copyDomain(Legacy.bundleID, into: UserDefaults.standard)
            copySecrets(from: KeychainSecretStore(service: Legacy.keychainService), to: KeychainSecretStore(service: keychainService))
        }
        copyDataDirSuites(in: preferences, from: Legacy.dataDirSuitePrefix, to: AppDefaults.dataDirSuitePrefix)
        for root in Set(roots) {
            moveDataDirectory(from: legacyRoot(for: root), to: root)
        }
        for root in Set(roots) {
            renameProjectFolders(projectPaths(in: AppPaths(root: root).database))
        }
        defaults.set(true, forKey: doneKey)
    }

    static func legacyRoot(for root: URL) -> URL {
        root.standardizedFileURL == defaultRoot.standardizedFileURL ? legacyDefaultRoot : root
    }

    static func copyDomain(_ name: String, into target: UserDefaults) {
        guard let values = UserDefaults.standard.persistentDomain(forName: name) else { return }
        for (key, value) in values where target.object(forKey: key) == nil {
            target.set(value, forKey: key)
        }
    }

    static func copyDataDirSuites(in preferences: URL, from oldPrefix: String, to newPrefix: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for file in files where file.hasPrefix(oldPrefix) && file.hasSuffix(".plist") {
            let suffix = file.dropFirst(oldPrefix.count).dropLast(".plist".count)
            guard let target = UserDefaults(suiteName: newPrefix + suffix) else { continue }
            copyDomain(oldPrefix + suffix, into: target)
        }
    }

    static func copySecrets(from old: any SecretStore, to new: any SecretStore) {
        for key in SecretKey.allCases {
            guard (try? new.read(key)) == nil, let value = try? old.read(key) else { continue }
            try? new.write(value, for: key)
        }
    }

    static func moveDataDirectory(from legacy: URL, to root: URL, fileManager: FileManager = .default) {
        if legacy.standardizedFileURL != root.standardizedFileURL,
           fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: root.path) {
            try? fileManager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.moveItem(at: legacy, to: root)
        }
        let database = AppPaths(root: root).database
        guard !fileManager.fileExists(atPath: database.path) else { return }
        let oldDatabase = root.appending(path: Legacy.database)
        guard fileManager.fileExists(atPath: oldDatabase.path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: oldDatabase.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: URL(fileURLWithPath: database.path + suffix))
        }
    }

    static func projectPaths(in database: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: database.path),
              let queue = try? DatabaseQueue(path: database.path) else { return [] }
        let paths = (try? queue.read { db in try String.fetchAll(db, sql: "SELECT path FROM project WHERE host IS NULL") }) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func renameProjectFolders(_ repos: [URL], fileManager: FileManager = .default) {
        for repo in repos {
            let old = repo.appending(path: Legacy.projectDirectory, directoryHint: .isDirectory)
            let new = repo.appending(path: ProjectConfig.directoryName, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) {
                try? fileManager.moveItem(at: old, to: new)
            }
            rewriteGitignore(repo.appending(path: ".gitignore"))
        }
    }

    static func rewriteGitignore(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(Legacy.projectDirectory) else { return }
        let rewritten = text.replacingOccurrences(of: Legacy.projectDirectory, with: ProjectConfig.directoryName)
        try? rewritten.write(to: url, atomically: true, encoding: .utf8)
    }

    static func removeLegacyLaunchAgent() {
        let target = "gui/\(getuid())/\(Legacy.daemonLabel)"
        run("/bin/launchctl", ["bootout", target])
        run("/bin/launchctl", ["disable", target])
        run("/usr/bin/pkill", ["-x", Legacy.daemonName])
        let plist = URL.libraryDirectory.appending(path: "LaunchAgents/\(Legacy.daemonLabel).plist")
        try? FileManager.default.removeItem(at: plist)
        waitForLegacyDaemonToExit()
    }

    static func waitForLegacyDaemonToExit() {
        for _ in 0..<50 {
            guard run("/usr/bin/pgrep", ["-x", Legacy.daemonName]) == 0 else { return }
            usleep(100_000)
        }
    }

    public static let remoteCleanupScript = """
        launchctl bootout gui/$(id -u)/\(Legacy.daemonLabel) >/dev/null 2>&1 || true
        rm -f ~/Library/LaunchAgents/\(Legacy.daemonLabel).plist
        old="$HOME/Library/Application Support/\(Legacy.appName)"
        new="$HOME/Library/Application Support/Saturn"
        if [ -d "$old" ] && [ ! -e "$new" ]; then mv "$old" "$new"; fi
        if [ -f "$new/\(Legacy.database)" ] && [ ! -e "$new/saturn.sqlite" ]; then
          for s in "" -wal -shm; do if [ -e "$new/\(Legacy.database)$s" ]; then mv "$new/\(Legacy.database)$s" "$new/saturn.sqlite$s"; fi; done
        fi
        rm -rf ~/\(Legacy.homeDirectory)/bin
        """

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
