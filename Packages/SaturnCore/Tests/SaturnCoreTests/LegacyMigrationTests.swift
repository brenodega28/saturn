import Foundation
import Testing
@testable import SaturnCore

@Suite struct LegacyMigrationTests {
    let fm = FileManager.default

    func temporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appending(path: "saturn-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func movesTheLegacyDataDirectoryAndRenamesTheDatabase() throws {
        let base = try temporaryDirectory()
        let legacy = base.appending(path: "Ensemble")
        let root = base.appending(path: "Saturn")
        try write("db", to: legacy.appending(path: LegacyMigration.Legacy.database))
        try write("wal", to: legacy.appending(path: LegacyMigration.Legacy.database + "-wal"))
        try write("{}", to: legacy.appending(path: "daemon.json"))

        LegacyMigration.moveDataDirectory(from: legacy, to: root)

        #expect(!fm.fileExists(atPath: legacy.path))
        #expect(read(root.appending(path: "saturn.sqlite")) == "db")
        #expect(read(root.appending(path: "saturn.sqlite-wal")) == "wal")
        #expect(read(root.appending(path: "daemon.json")) == "{}")
    }

    @Test func leavesAnExistingSaturnDirectoryAlone() throws {
        let base = try temporaryDirectory()
        let legacy = base.appending(path: "Ensemble")
        let root = base.appending(path: "Saturn")
        try write("old", to: legacy.appending(path: LegacyMigration.Legacy.database))
        try write("new", to: root.appending(path: "saturn.sqlite"))

        LegacyMigration.moveDataDirectory(from: legacy, to: root)

        #expect(read(legacy.appending(path: LegacyMigration.Legacy.database)) == "old")
        #expect(read(root.appending(path: "saturn.sqlite")) == "new")
    }

    @Test func renamesTheDatabaseInsideACustomDataDirectory() throws {
        let root = try temporaryDirectory()
        try write("db", to: root.appending(path: LegacyMigration.Legacy.database))

        LegacyMigration.moveDataDirectory(from: LegacyMigration.legacyRoot(for: root), to: root)
        LegacyMigration.moveDataDirectory(from: LegacyMigration.legacyRoot(for: root), to: root)

        #expect(read(root.appending(path: "saturn.sqlite")) == "db")
        #expect(!fm.fileExists(atPath: root.appending(path: LegacyMigration.Legacy.database).path))
    }

    @Test func renamesProjectFoldersAndRewritesGitignore() throws {
        let repo = try temporaryDirectory()
        try write("id: small-task", to: repo.appending(path: ".ensemble/workflows/small-task.yaml"))
        try write("node_modules/\n.ensemble/local.yaml\n*.ensemble-tmp\n", to: repo.appending(path: ".gitignore"))

        LegacyMigration.renameProjectFolders([repo])

        #expect(!fm.fileExists(atPath: repo.appending(path: ".ensemble").path))
        #expect(read(repo.appending(path: ".saturn/workflows/small-task.yaml")) == "id: small-task")
        #expect(read(repo.appending(path: ".gitignore")) == "node_modules/\n.saturn/local.yaml\n*.saturn-tmp\n")
    }

    @Test func keepsAnExistingSaturnFolder() throws {
        let repo = try temporaryDirectory()
        try write("old", to: repo.appending(path: ".ensemble/permissions.yaml"))
        try write("new", to: repo.appending(path: ".saturn/permissions.yaml"))

        LegacyMigration.renameProjectFolders([repo])

        #expect(read(repo.appending(path: ".ensemble/permissions.yaml")) == "old")
        #expect(read(repo.appending(path: ".saturn/permissions.yaml")) == "new")
    }

    @Test func copiesDataDirSuitesWithoutDeletingOrOverwriting() throws {
        let preferences = try temporaryDirectory()
        let token = UUID().uuidString
        let oldPrefix = "test.old.\(token)."
        let newPrefix = "test.new.\(token)."
        let old = try #require(UserDefaults(suiteName: oldPrefix + "abc"))
        let new = try #require(UserDefaults(suiteName: newPrefix + "abc"))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: oldPrefix + "abc")
            UserDefaults.standard.removePersistentDomain(forName: newPrefix + "abc")
        }
        old.set("dark", forKey: "appearance")
        old.set(14.0, forKey: "editor.fontSize")
        new.set(13.0, forKey: "editor.fontSize")
        try write("", to: preferences.appending(path: oldPrefix + "abc.plist"))

        LegacyMigration.copyDataDirSuites(in: preferences, from: oldPrefix, to: newPrefix)

        #expect(new.string(forKey: "appearance") == "dark")
        #expect(new.double(forKey: "editor.fontSize") == 13)
        #expect(old.string(forKey: "appearance") == "dark")
    }

    @Test func copiesSecretsOnlyWhenTheNewStoreHasNone() throws {
        let old = InMemorySecretStore([.anthropicAPIKey: "sk-old"])
        let empty = InMemorySecretStore()
        let filled = InMemorySecretStore([.anthropicAPIKey: "sk-new"])

        LegacyMigration.copySecrets(from: old, to: empty)
        LegacyMigration.copySecrets(from: old, to: filled)

        #expect(try empty.read(.anthropicAPIKey) == "sk-old")
        #expect(try filled.read(.anthropicAPIKey) == "sk-new")
        #expect(try old.read(.anthropicAPIKey) == "sk-old")
    }

    @Test func runsOnceForACustomDataDirectory() throws {
        let root = try temporaryDirectory()
        let repo = try temporaryDirectory()
        try write("permissions: []", to: repo.appending(path: ".ensemble/permissions.yaml"))
        do {
            let database = try AppDatabase.open(at: root.appending(path: LegacyMigration.Legacy.database))
            try database.openProject(at: repo)
        }
        let suite = "test.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        LegacyMigration.runIfNeeded(paths: [AppPaths(root: root)], defaults: defaults, preferences: root)

        #expect(defaults.bool(forKey: LegacyMigration.doneKey))
        #expect(fm.fileExists(atPath: root.appending(path: "saturn.sqlite").path))
        #expect(read(repo.appending(path: ".saturn/permissions.yaml")) == "permissions: []")

        try write("again", to: repo.appending(path: ".ensemble/permissions.yaml"))
        LegacyMigration.runIfNeeded(paths: [AppPaths(root: root)], defaults: defaults, preferences: root)

        #expect(read(repo.appending(path: ".ensemble/permissions.yaml")) == "again")
    }
}
