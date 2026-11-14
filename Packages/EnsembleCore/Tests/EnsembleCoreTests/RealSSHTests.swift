import Foundation
import Testing
@testable import EnsembleCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENSEMBLE_REAL_SSH_HOST"] != nil))
struct RealSSHTests {
    let environment = ProcessInfo.processInfo.environment

    @Test func browsesAndResolvesARepositoryOnARealHost() async throws {
        let destination = try #require(environment["ENSEMBLE_REAL_SSH_HOST"])
        let repository = try #require(environment["ENSEMBLE_REAL_SSH_REPO"])
        let executable = environment["ENSEMBLE_REAL_SSH_EXECUTABLE"].map { URL(fileURLWithPath: $0) } ?? SSHClient.defaultExecutable
        let host = RemoteHost(client: SSHClient(destination: destination, executable: executable))

        let info = try await host.probe()
        #expect(info.home.hasPrefix("/"))
        #expect(info.gitPath != nil)

        let home = try await host.list("~/")
        #expect(home.path == info.home)

        let parent = (repository as NSString).deletingLastPathComponent
        let name = (repository as NSString).lastPathComponent
        let listing = try await host.list(parent)
        #expect(listing.entries.contains(RemoteDirectory.Entry(name: name, isGitRepository: true)))

        let browser = await RemoteFolderBrowser(lister: host, input: parent + "/" + String(name.prefix(3)))
        await browser.loaded()
        #expect(await browser.suggestions.first?.name == name)

        #expect(try await host.repositoryRoot(containing: repository) == repository)
        #expect(try await host.currentBranch(in: repository) != nil)
        await #expect(throws: RemoteFolderError.notARepository(info.home)) { try await host.repositoryRoot(containing: info.home) }
    }
}
