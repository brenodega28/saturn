import Foundation
import Testing
@testable import EnsembleCore

@Suite struct SkillPluginTests {
    struct Fixture {
        let root: URL
        let repository: URL
        let claude: URL
        let log: URL
        let installPath: URL

        var installer: SkillPluginInstaller {
            SkillPluginInstaller(claude: claude, runner: CommandRunner())
        }

        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func makeFixture(marketplaceAdd: String? = nil, install: String? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-plugins-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repository = root.appending(path: "repo", directoryHint: .isDirectory)
        let installPath = root.appending(path: "cache/sentry-skills/sentry-skills/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for skill in ["commit", "code-review"] {
            let folder = installPath.appending(path: "skills/\(skill)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(skill)\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: installPath.appending(path: "skills/notes"), withIntermediateDirectories: true)

        let log = root.appending(path: "calls.log")
        let addLine = marketplaceAdd ?? #"{"command":"marketplace-add","outcome":"ok","marketplace":"sentry-skills","message":"Successfully added"}"#
        let installLine = install ?? #"{"command":"install","outcome":"ok","plugin":"sentry-skills@sentry-skills","pluginId":"sentry-skills@sentry-skills","scope":"project"}"#
        let listJSON = """
        [{"id":"frontend-design@claude-plugins-official","scope":"user","enabled":true,"installPath":"/nowhere","projectEnabled":false},\
        {"id":"sentry-skills@sentry-skills","scope":"project","enabled":true,"installPath":"/elsewhere","projectPath":"/other/project","projectEnabled":true},\
        {"id":"sentry-skills@sentry-skills","scope":"project","enabled":true,"installPath":"\(installPath.path)","projectPath":"\(realPath(of: repository))","projectEnabled":true}]
        """
        let script = """
        #!/bin/sh
        echo "$(pwd -P)|$*" >> '\(log.path)'
        case "$2 $3" in
          "marketplace add") echo 'Cloning…'; echo '\(addLine)' ;;
          "install "*) echo '\(installLine)' ;;
          "list --json") echo '\(listJSON)' ;;
          *) echo "unexpected $*" >&2; exit 2 ;;
        esac
        """
        let claude = root.appending(path: "claude")
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return Fixture(root: root, repository: repository, claude: claude, log: log, installPath: installPath)
    }

    @Test func installsIntoTheProjectScopeAndReportsThePluginSkills() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let plugin = try await fixture.installer.install(plugin: " sentry-skills ", from: " getsentry/skills ", in: fixture.repository)

        #expect(plugin == SkillPlugin(id: "sentry-skills@sentry-skills", skills: ["sentry-skills:code-review", "sentry-skills:commit"]))
        let repository = realPath(of: fixture.repository)
        #expect(fixture.calls() == [
            "\(repository)|plugin marketplace add getsentry/skills --scope project --json",
            "\(repository)|plugin install sentry-skills@sentry-skills --scope project --json",
            "\(repository)|plugin list --json",
        ])
    }

    @Test func aQualifiedPluginNameIsPassedThrough() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        try await fixture.installer.install(plugin: "sentry-skills@other", from: "getsentry/skills", in: fixture.repository)
        #expect(fixture.calls()[1].hasSuffix("plugin install sentry-skills@other --scope project --json"))
    }

    @Test func onlyPluginsEnabledForTheProjectAreListedOncePreferringThisProjectsInstall() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let plugins = try await fixture.installer.projectPlugins(in: fixture.repository)
        #expect(plugins.map(\.id) == ["sentry-skills@sentry-skills"])
        #expect(plugins.first?.skills == ["sentry-skills:code-review", "sentry-skills:commit"])
        #expect(plugins.first?.name == "sentry-skills")
    }

    @Test func aFailedOutcomeIsAnErrorEvenWhenTheExitCodeIsZero() async throws {
        let fixture = try makeFixture(marketplaceAdd: #"{"command":"marketplace-add","outcome":"failed","message":"Repository not found"}"#)
        defer { fixture.cleanUp() }

        await #expect(throws: SkillPluginError.failed(command: "marketplace add", message: "Repository not found")) {
            try await fixture.installer.install(plugin: "sentry-skills", from: "getsentry/missing", in: fixture.repository)
        }
        #expect(fixture.calls().count == 1)
    }

    @Test func aMissingPluginIsReported() async throws {
        let fixture = try makeFixture(install: #"{"command":"install","outcome":"failed","message":"Plugin \"nope\" not found in marketplace \"sentry-skills\""}"#)
        defer { fixture.cleanUp() }

        await #expect(throws: SkillPluginError.failed(command: "install", message: #"Plugin "nope" not found in marketplace "sentry-skills""#)) {
            try await fixture.installer.install(plugin: "nope", from: "getsentry/skills", in: fixture.repository)
        }
    }

    @Test func emptyFieldsAreRejectedWithoutRunningClaude() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        await #expect(throws: SkillPluginError.emptySource) {
            try await fixture.installer.install(plugin: "sentry-skills", from: "  ", in: fixture.repository)
        }
        await #expect(throws: SkillPluginError.emptyPlugin) {
            try await fixture.installer.install(plugin: "", from: "getsentry/skills", in: fixture.repository)
        }
        #expect(fixture.calls().isEmpty)
    }

    @Test func pluginSkillsCountAsInstalledForAgents() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let skills = ["sentry-skills:code-review", "sentry-skills:nope"]

        #expect(SkillLibrary.unknownSkills(skills, in: fixture.repository, pluginSkills: ["sentry-skills:code-review"]) == ["sentry-skills:nope"])
        let context = RoleContext.build(kind: .checker, skills: skills, config: ProjectConfig(), repository: fixture.repository, pluginSkills: ["sentry-skills:code-review"])
        #expect(context.warnings == [.missingSkill("sentry-skills:nope")])
    }
}
