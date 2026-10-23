import Foundation
import Testing
@testable import EnsembleCore

@Suite struct EnvironmentCheckerTests {
    @Test func reportsMissingToolsAndNoProvider() async {
        let checker = EnvironmentChecker(
            locator: ToolLocator(searchDirectories: []),
            runner: CommandRunner(),
            secrets: InMemorySecretStore()
        )

        let report = await checker.check()

        #expect(report.git == .missing)
        #expect(report.claude == .missing)
        #expect(report.provider == .none)
        #expect(!report.isReady)
    }

    @Test func storedAPIKeyCountsAsProviderAccess() async throws {
        let bin = try FakeTools.make([
            "git": "echo 'git version 2.50.1'",
            "claude": "echo '2.1.309 (Claude Code)'",
        ])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(
            locator: ToolLocator(searchDirectories: [bin]),
            runner: CommandRunner(),
            secrets: InMemorySecretStore([.anthropicAPIKey: "sk-ant-test"])
        )

        let report = await checker.check()

        #expect(report.git == .found(path: bin.appending(path: "git"), version: "2.50.1"))
        #expect(report.claude == .found(path: bin.appending(path: "claude"), version: "2.1.309"))
        #expect(report.provider == .apiKey)
        #expect(report.isReady)
    }

    @Test func claudeLoginCountsAsProviderAccess() async throws {
        let bin = try FakeTools.make([
            "claude": """
            if [ "$1" = "auth" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai"}'; else echo '2.1.309 (Claude Code)'; fi
            """,
        ])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(locator: ToolLocator(searchDirectories: [bin]), runner: CommandRunner(), secrets: InMemorySecretStore())

        let report = await checker.check()

        #expect(report.provider == .claudeLogin(method: "claude.ai"))
        #expect(report.git == .missing)
        #expect(!report.isReady)
    }

    @Test func loggedOutClaudeWithoutKeyHasNoProvider() async throws {
        let bin = try FakeTools.make([
            "claude": """
            if [ "$1" = "auth" ]; then echo '{"loggedIn": false}'; exit 1; else echo '2.1.309 (Claude Code)'; fi
            """,
        ])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(locator: ToolLocator(searchDirectories: [bin]), runner: CommandRunner(), secrets: InMemorySecretStore([.anthropicAPIKey: "   "]))

        #expect(await checker.check().provider == .none)
    }

    @Test func failingToolIsReportedAsBroken() async throws {
        let bin = try FakeTools.make(["git": "echo 'dyld: library not loaded' >&2; exit 3"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(locator: ToolLocator(searchDirectories: [bin]), runner: CommandRunner(), secrets: InMemorySecretStore())

        #expect(await checker.check().git == .broken(path: bin.appending(path: "git"), message: "dyld: library not loaded"))
    }

    @Test func locatorMergesPathWithWellKnownDirectories() {
        let locator = ToolLocator(environment: ["PATH": "/custom/bin:/usr/bin"], homeDirectory: URL(fileURLWithPath: "/Users/me"))
        let paths = locator.searchDirectories.map(\.path)

        #expect(paths.first == "/custom/bin")
        #expect(paths.filter { $0 == "/usr/bin" }.count == 1)
        #expect(paths.contains("/opt/homebrew/bin"))
        #expect(paths.contains("/Users/me/.local/bin"))
        #expect(locator.environment(merging: ["HOME": "/Users/me"])["PATH"] == locator.searchPath)
    }

    @Test func inMemorySecretStoreRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.write("one", for: .githubToken)
        try store.write("two", for: .githubToken)
        #expect(try store.read(.githubToken) == "two")
        try store.delete(.githubToken)
        #expect(try store.read(.githubToken) == nil)
    }
}

enum FakeTools {
    static func make(_ scripts: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ensemble-bin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, body) in scripts {
            let url = directory.appending(path: name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return directory
    }
}
