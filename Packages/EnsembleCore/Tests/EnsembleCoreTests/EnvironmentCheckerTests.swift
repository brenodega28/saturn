import Foundation
import Testing
@testable import EnsembleCore

@Suite struct EnvironmentCheckerTests {
    @Test func reportsMissingToolsAndUnchosenProvider() async {
        let checker = EnvironmentChecker(
            locator: ToolLocator(searchDirectories: []),
            runner: CommandRunner(),
            secrets: InMemorySecretStore(),
            mode: nil
        )

        let report = await checker.check()

        #expect(report.git == .missing)
        #expect(report.claude == .missing)
        #expect(report.provider == .notChosen)
        #expect(!report.isReady)
    }

    @Test func nothingCountsUntilAModeIsChosen() async throws {
        let bin = try FakeTools.make([
            "git": "echo 'git version 2.50.1'",
            "claude": signedInClaude,
        ])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(
            locator: ToolLocator(searchDirectories: [bin]),
            runner: CommandRunner(),
            secrets: InMemorySecretStore([.anthropicAPIKey: "sk-ant-test"]),
            mode: nil
        )

        let report = await checker.check()

        #expect(report.git.isOK && report.claude.isOK)
        #expect(report.provider == .notChosen)
        #expect(!report.isReady)
    }

    @Test func apiKeyModeNeedsAStoredKey() async throws {
        let bin = try FakeTools.make(["git": "echo 'git version 2.50.1'", "claude": signedInClaude])
        defer { try? FileManager.default.removeItem(at: bin) }
        let locator = ToolLocator(searchDirectories: [bin])

        let withoutKey = await EnvironmentChecker(locator: locator, runner: CommandRunner(), secrets: InMemorySecretStore([.anthropicAPIKey: "  "]), mode: .apiKey).check()
        let withKey = await EnvironmentChecker(locator: locator, runner: CommandRunner(), secrets: InMemorySecretStore([.anthropicAPIKey: "sk-ant-test"]), mode: .apiKey).check()

        #expect(withoutKey.provider == .apiKey(isStored: false))
        #expect(!withoutKey.isReady)
        #expect(withKey.provider == .apiKey(isStored: true))
        #expect(withKey.isReady)
        #expect(withKey.git == .found(path: bin.appending(path: "git"), version: "2.50.1"))
        #expect(withKey.claude == .found(path: bin.appending(path: "claude"), version: "2.1.309"))
    }

    @Test func signInModeChecksTheLoginWithoutTheShellKey() async throws {
        let bin = try FakeTools.make(["git": "echo 'git version 2.50.1'", "claude": signedInClaude])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(
            locator: ToolLocator(searchDirectories: [bin]),
            runner: CommandRunner(environment: ["ANTHROPIC_API_KEY": "sk-ant-shell", "PATH": "/usr/bin:/bin"]),
            secrets: InMemorySecretStore([.anthropicAPIKey: "sk-ant-test"]),
            mode: .claudeSignIn
        )

        let report = await checker.check()

        #expect(report.provider == .claudeSignIn(account: "me@example.com", isSignedIn: true))
        #expect(report.isReady)
    }

    @Test func signInModeRejectsLoggedOutOrKeyOnlyClaude() async throws {
        for body in [
            #"if [ "$1" = "auth" ]; then echo '{"loggedIn": false}'; exit 1; else echo '2.1.309 (Claude Code)'; fi"#,
            #"if [ "$1" = "auth" ]; then echo '{"loggedIn": true, "authMethod": "api_key"}'; else echo '2.1.309 (Claude Code)'; fi"#,
        ] {
            let bin = try FakeTools.make(["claude": body])
            defer { try? FileManager.default.removeItem(at: bin) }
            let checker = EnvironmentChecker(locator: ToolLocator(searchDirectories: [bin]), runner: CommandRunner(), secrets: InMemorySecretStore(), mode: .claudeSignIn)

            #expect(await checker.check().provider == .claudeSignIn(account: nil, isSignedIn: false))
        }
    }

    let signedInClaude = #"""
    if [ "$1" = "auth" ]; then
      if [ -n "$ANTHROPIC_API_KEY" ]; then echo '{"loggedIn": true, "authMethod": "api_key"}'; else echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com"}'; fi
    else echo '2.1.309 (Claude Code)'; fi
    """#

    @Test func failingToolIsReportedAsBroken() async throws {
        let bin = try FakeTools.make(["git": "echo 'dyld: library not loaded' >&2; exit 3"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let checker = EnvironmentChecker(locator: ToolLocator(searchDirectories: [bin]), runner: CommandRunner(), secrets: InMemorySecretStore(), mode: nil)

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
        try store.write("one", for: .anthropicAPIKey)
        try store.write("two", for: .anthropicAPIKey)
        #expect(try store.read(.anthropicAPIKey) == "two")
        try store.delete(.anthropicAPIKey)
        #expect(try store.read(.anthropicAPIKey) == nil)
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
