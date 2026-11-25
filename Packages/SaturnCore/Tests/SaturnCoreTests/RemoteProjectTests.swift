import Foundation
import GRDB
import Testing
@testable import SaturnCore

@Suite struct SSHDestinationTests {
    @Test func keepsAliasesAndUserAtHost() throws {
        #expect(try SSHDestination.normalize("  devbox ") == "devbox")
        #expect(try SSHDestination.normalize("me@devbox.local") == "me@devbox.local")
        #expect(try SSHDestination.normalize("ssh://me@devbox:2200") == "ssh://me@devbox:2200")
    }

    @Test func turnsAPortSuffixIntoAnSSHURI() throws {
        #expect(try SSHDestination.normalize("devbox:2200") == "ssh://devbox:2200")
        #expect(try SSHDestination.normalize("me@10.0.0.4:22") == "ssh://me@10.0.0.4:22")
        #expect(SSHDestination.displayName("ssh://me@10.0.0.4:22") == "me@10.0.0.4:22")
    }

    @Test func rejectsOptionsWhitespaceAndBadPorts() {
        #expect(throws: SSHDestinationError.empty) { try SSHDestination.normalize("   ") }
        #expect(throws: SSHDestinationError.invalid("-oProxyCommand=evil")) { try SSHDestination.normalize("-oProxyCommand=evil") }
        #expect(throws: SSHDestinationError.invalid("dev box")) { try SSHDestination.normalize("dev box") }
        #expect(throws: SSHDestinationError.invalid("devbox:ssh")) { try SSHDestination.normalize("devbox:ssh") }
        #expect(throws: SSHDestinationError.invalid("devbox:")) { try SSHDestination.normalize("devbox:") }
    }

    @Test func readsConcreteHostAliasesFromSSHConfig() {
        let config = """
        Host *
          ServerAliveInterval 30
        Host devbox build-1
          HostName 10.0.0.4
        host=gpu
        Host !bastion web-?
        Match host other
        Host devbox
        """
        #expect(SSHConfigHosts.parse(config) == ["devbox", "build-1", "gpu"])
    }

    @Test func followsIncludesRelativeToTheSSHFolderWithGlobsAndNesting() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "saturn-sshconfig-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh.appending(path: "config.d"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".orbstack/ssh"), withIntermediateDirectories: true)
        try "Include ~/.orbstack/ssh/config\nHost devbox\nInclude config.d/*\n".write(to: ssh.appending(path: "config"), atomically: true, encoding: .utf8)
        try "Host orb\n".write(to: home.appending(path: ".orbstack/ssh/config"), atomically: true, encoding: .utf8)
        try "Host work-a\nInclude ../config\n".write(to: ssh.appending(path: "config.d/a"), atomically: true, encoding: .utf8)
        try "Host work-b devbox\n".write(to: ssh.appending(path: "config.d/b"), atomically: true, encoding: .utf8)

        let hosts = SSHConfigHosts.load(from: ssh.appending(path: "config"), home: home)

        #expect(hosts == ["orb", "devbox", "work-a", "work-b"])
    }
}

@Suite struct ShellQuoteTests {
    @Test func quotesOnlyWhatNeedsIt() {
        #expect(ShellQuote.quote("/home/me/code") == "/home/me/code")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("my repo") == "'my repo'")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.command(["git", "status"], in: "/srv/a b") == "cd -- '/srv/a b' && git status")
    }

    @Test func survivesARoundTripThroughAShell() async throws {
        let tricky = ["a b", "it's", "$HOME", "`id`", "semi;colon", "new\nline", "*"]
        let result = try await CommandRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", ShellQuote.command(["printf", "%s|"] + tricky)])
        #expect(result.standardOutput == tricky.map { $0 + "|" }.joined())
    }
}

@Suite struct RemotePathCompletionTests {
    let entries = ["api", "Apps", "web", ".config", "zapier", "notes"].map { RemoteDirectory.Entry(name: $0, isGitRepository: false) }

    @Test func splitsTheInputAtTheLastSlash() {
        #expect(RemotePathCompletion(input: "") == RemotePathCompletion(input: "~/"))
        #expect(RemotePathCompletion(input: "~").directory == "~/")
        let completion = RemotePathCompletion(input: "~/code/ens")
        #expect(completion.directory == "~/code/")
        #expect(completion.filter == "ens")
        #expect(RemotePathCompletion(input: "/srv/").filter == "")
        #expect(RemotePathCompletion(input: "proj").directory == "~/")
    }

    @Test func filtersPrefixMatchesFirstAndHidesDotFolders() {
        #expect(RemotePathCompletion(input: "~/").suggestions(from: entries).map(\.name) == ["api", "Apps", "web", "zapier", "notes"])
        #expect(RemotePathCompletion(input: "~/ap").suggestions(from: entries).map(\.name) == ["api", "Apps", "zapier"])
        #expect(RemotePathCompletion(input: "~/.c").suggestions(from: entries).map(\.name) == [".config"])
    }

    @Test func completesIntoTheChosenFolder() {
        let completion = RemotePathCompletion(input: "/srv/w")
        #expect(completion.completion(for: RemoteDirectory.Entry(name: "web", isGitRepository: true)) == "/srv/web/")
    }
}

@Suite struct RemoteHostTests {
    @Test func parsesNULSeparatedListings() throws {
        let output = "/home/me\0gshop front\0dnotes\0dodd\nname\0"
        let listing = try RemoteHost.parseListing(output)
        #expect(listing.path == "/home/me")
        #expect(listing.entries == [
            RemoteDirectory.Entry(name: "notes", isGitRepository: false),
            RemoteDirectory.Entry(name: "odd\nname", isGitRepository: false),
            RemoteDirectory.Entry(name: "shop front", isGitRepository: true),
        ])
        #expect(throws: RemoteFolderError.unexpectedOutput) { try RemoteHost.parseListing("") }
    }

    @Test func passesSafeSSHOptionsAndEndsOptionParsingBeforeTheHost() {
        let client = SSHClient(destination: "devbox", controlDirectory: URL(fileURLWithPath: "/tmp/ctl"))
        let arguments = client.arguments(for: "true")
        #expect(arguments.suffix(3) == ["--", "devbox", "true"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ControlPath=/tmp/ctl/%C"))
        #expect(!SSHClient(destination: "devbox", controlDirectory: nil).arguments(for: "true").contains("ControlMaster=auto"))
    }

    @Test func listsProbesAndFindsRepositoriesOnTheHost() async throws {
        let host = try FakeSSHHost()
        defer { host.remove() }
        try host.makeDirectory("code/shop/.git")
        try host.makeDirectory("code/shop/src")
        try host.makeDirectory("code/it's here")
        try host.makeDirectory("code/.cache")
        try host.write("code/readme.txt")
        try await host.initRepository("code/shop")

        let remote = host.remote
        let listing = try await remote.list("~/code")
        #expect(listing.path == host.home.appending(path: "code").path)
        #expect(listing.entries == [
            RemoteDirectory.Entry(name: ".cache", isGitRepository: false),
            RemoteDirectory.Entry(name: "it's here", isGitRepository: false),
            RemoteDirectory.Entry(name: "shop", isGitRepository: true),
        ])

        let info = try await remote.probe()
        #expect(info.home == host.home.path)
        #expect(info.gitPath?.hasSuffix("/git") == true)

        let root = try await remote.repositoryRoot(containing: "~/code/shop/src")
        #expect(URL(fileURLWithPath: root).resolvingSymlinksInPath() == host.home.appending(path: "code/shop").resolvingSymlinksInPath())
        #expect(try await remote.currentBranch(in: root) == "main")

        await #expect(throws: RemoteFolderError.notARepository("~/code")) { try await remote.repositoryRoot(containing: "~/code") }
        await #expect(throws: RemoteFolderError.notFound("~/missing")) { try await remote.list("~/missing") }
        await #expect(throws: RemoteFolderError.notFound("~/missing")) { try await remote.repositoryRoot(containing: "~/missing") }
    }

    @Test func reportsSSHFailuresWithAHint() async throws {
        let host = try FakeSSHHost(failure: "Host key verification failed.")
        defer { host.remove() }
        do {
            _ = try await host.remote.probe()
            Issue.record("Expected the probe to fail")
        } catch let error as SSHError {
            #expect(error.isHostKeyProblem)
            #expect(error.localizedDescription.contains("ssh devbox"))
        }
    }
}

@Suite @MainActor struct RemoteFolderBrowserTests {
    final class CountingLister: RemoteDirectoryListing, @unchecked Sendable {
        let lock = NSLock()
        var requests: [String] = []
        let tree: [String: RemoteDirectory]

        init(tree: [String: RemoteDirectory]) { self.tree = tree }

        func list(_ path: String) async throws -> RemoteDirectory {
            lock.withLock { requests.append(path) }
            guard let directory = tree[path] else { throw RemoteFolderError.notFound(path) }
            return directory
        }
    }

    static func directory(_ path: String, _ names: String...) -> RemoteDirectory {
        RemoteDirectory(path: path, entries: names.map { RemoteDirectory.Entry(name: $0, isGitRepository: $0.hasSuffix("repo")) })
    }

    let lister = CountingLister(tree: [
        "~/": directory("/home/me", "code", "docs", "data"),
        "~/code/": directory("/home/me/code", "saturn-repo", "site"),
        "/home/": directory("/home", "me"),
    ])

    @Test func listsEachDirectoryOnceWhileTyping() async {
        let browser = RemoteFolderBrowser(lister: lister)
        await browser.loaded()
        #expect(browser.suggestions.map(\.name) == ["code", "docs", "data"])

        browser.input = "~/d"
        browser.input = "~/da"
        #expect(browser.suggestions.map(\.name) == ["data"])

        browser.input = "~/code/"
        await browser.loaded()
        #expect(browser.suggestions.map(\.name) == ["saturn-repo", "site"])
        #expect(browser.resolvedPath == "/home/me/code")
        #expect(lister.requests == ["~/", "~/code/"])
    }

    @Test func movesTheHighlightAndCompletesWithTab() async {
        let browser = RemoteFolderBrowser(lister: lister)
        await browser.loaded()
        browser.moveHighlight(by: 1)
        browser.moveHighlight(by: 1)
        #expect(browser.highlightedEntry?.name == "docs")
        browser.moveHighlight(by: -2)
        #expect(browser.highlightedEntry?.name == "data")

        browser.input = "~/co"
        #expect(browser.highlighted == nil)
        #expect(browser.completeHighlighted())
        #expect(browser.input == "~/code/")
    }

    @Test func goesUpFromHomeToTheRealParent() async {
        let browser = RemoteFolderBrowser(lister: lister, input: "~/code/")
        await browser.loaded()
        browser.goUp()
        #expect(browser.input == "~/")
        await browser.loaded()
        browser.goUp()
        #expect(browser.input == "/home/")
        await browser.loaded()
        #expect(browser.suggestions.map(\.name) == ["me"])
    }

    @Test func showsWhyAFolderCouldNotBeListed() async {
        let browser = RemoteFolderBrowser(lister: lister, input: "~/nope/")
        await browser.loaded()
        #expect(browser.status == .failed(RemoteFolderError.notFound("~/nope/").localizedDescription))
        #expect(browser.suggestions.isEmpty)
    }
}

@Suite struct RemoteProjectStoreTests {
    @Test func keepsLocalAndRemoteProjectsWithTheSamePathApart() throws {
        let database = try AppDatabase.inMemory()
        let local = try database.openProject(at: URL(fileURLWithPath: "/srv/shop"))
        let remote = try database.openRemoteProject(path: "/srv/shop", host: "devbox")
        let other = try database.openRemoteProject(path: "/srv/shop", host: "build-1")
        let again = try database.openRemoteProject(path: "/srv/shop", host: "devbox")

        #expect(Set([local.id, remote.id, other.id]).count == 3)
        #expect(again.id == remote.id)
        #expect(remote.name == "shop")
        #expect(remote.isRemote && !local.isRemote)
        #expect(remote.location == "devbox:/srv/shop")
        #expect(try database.openProjects().count == 3)
        #expect(try database.openProject(at: URL(fileURLWithPath: "/srv/shop")).id == local.id)
    }

    @Test func migratingKeepsExistingProjectsAndTheirChildren() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v20-permission-scopes")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO project (id, name, path, isOpen, createdAt, lastOpenedAt, settings) VALUES (7, 'shop', '/srv/shop', 1, 0, 0, '{}')")
            try db.execute(sql: "INSERT INTO task (projectId, title, body, source, status, createdAt, updatedAt) VALUES (7, 'Fix it', '', 'chat', 'open', 0, 0)")
        }
        let database = try AppDatabase(queue)

        let project = try #require(try database.project(id: 7))
        #expect(project.path == "/srv/shop")
        #expect(project.host == nil)
        #expect(try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM task WHERE projectId = 7") } == 1)

        try database.forgetProject(id: 7)
        #expect(try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM task") } == 0)
    }
}

struct FakeSSHHost {
    let root: URL
    let home: URL
    let executable: URL

    init(failure: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "saturn-ssh-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        executable = root.appending(path: "ssh")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let body = failure.map { "echo \(ShellQuote.quote($0)) >&2; exit 255" } ?? #"""
        while [ "$1" != "--" ]; do shift; done
        shift 2
        cd \#(ShellQuote.quote(home.path)) && exec env -i HOME=\#(ShellQuote.quote(home.path)) PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh /bin/sh -c "$1"
        """#
        try "#!/bin/sh\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    var remote: RemoteHost {
        RemoteHost(client: SSHClient(destination: "devbox", executable: executable, controlDirectory: nil))
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appending(path: path), withIntermediateDirectories: true)
    }

    func write(_ path: String) throws {
        try "x".write(to: home.appending(path: path), atomically: true, encoding: .utf8)
    }

    func initRepository(_ path: String) async throws {
        let directory = home.appending(path: path)
        try? FileManager.default.removeItem(at: directory.appending(path: ".git"))
        _ = try await CommandRunner().runChecked(URL(fileURLWithPath: "/usr/bin/git"), ["init", "-q", "-b", "main"], in: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite @MainActor struct RemoteProjectGuardTests {
    @Test func neverTouchesALocalFolderAtTheSamePathEvenWhenHandedLocalGit() async throws {
        let harness = try await AgentHarness.make()
        defer { harness.cleanUp() }
        let remote = try harness.database.openRemoteProject(path: harness.project.path, host: "saturn-test.invalid")

        await #expect(throws: RemoteProjectUnsupported.self) {
            try await harness.runtime.spawn(in: remote, kind: .builder, count: 1, git: harness.repo.git, name: "Ghost")
        }
        #expect(!FileManager.default.fileExists(atPath: harness.repo.root.appending(path: ".crew").path))
        #expect(try harness.database.agents(inProject: try #require(remote.id)).isEmpty)
    }
}
