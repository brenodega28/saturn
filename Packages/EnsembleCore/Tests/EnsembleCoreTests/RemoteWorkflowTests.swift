import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.serialized) struct RemoteWorkflowTests {
    @Test func featureDeliveryRunsEndToEndOnTheHost() async throws {
        let harness = try await AgentHarness.make(mode: "workflow")
        let host = try FakeSSHHost()
        let destination = "fakehost-\(UUID().uuidString.lowercased())"
        SSHClient.executableOverrides.withLock { $0[destination] = host.executable }
        RemoteMirror.rootOverrides.withLock { $0[destination] = host.root.appending(path: "app-data", directoryHint: .isDirectory) }
        defer {
            SSHClient.executableOverrides.withLock { $0[destination] = nil }
            RemoteMirror.rootOverrides.withLock { $0[destination] = nil }
            harness.cleanUp()
            host.remove()
        }

        try ProjectConfigLoader.installDefaults(repository: harness.repo.root)
        try LegacyWorkflows.install(repository: harness.repo.root)
        var feature = try #require(ProjectConfigLoader.load(repository: harness.repo.root).workflow("feature-delivery"))
        feature.end = WorkflowEnd(action: .merge, cleanUpWorktrees: true)
        try ProjectConfigLoader.write(feature, repository: harness.repo.root)
        try await harness.repo.git.run(["add", ".ensemble"], in: harness.repo.root)
        try await harness.repo.git.run(["commit", "-m", "Add Ensemble config"], in: harness.repo.root)
        try await harness.repo.git.run(["config", "user.name", "Host User"], in: harness.repo.root)
        try await harness.repo.git.run(["config", "user.email", "host-user"], in: harness.repo.root)

        let remoteClaude = host.root.appending(path: "claude-on-host")
        try "#!/bin/sh\nFAKE_DIR=\(ShellQuote.quote(harness.bin.path)) exec \(ShellQuote.quote(harness.bin.appending(path: "claude").path)) \"$@\"\n"
            .write(to: remoteClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remoteClaude.path)
        let client = SSHClient(destination: destination, executable: host.executable, controlDirectory: nil)
        let root = try await RemoteHost(client: client).repositoryRoot(containing: harness.repo.root.path)
        let project = try harness.database.openRemoteProject(path: root, host: destination)
        let location = RemoteMirror.location(forProject: project.id!, host: destination)
        try await RemoteMirror(directory: location.directory, manifestFile: location.manifest, repository: root, client: client).pull()
        #expect(ProjectConfigLoader.load(repository: project.filesRoot).workflow("feature-delivery") != nil)

        harness.runtime.claudeExecutable = nil
        harness.runtime.remoteHostProvider = { _ in
            RemoteAgentHost(client: client, claudePath: remoteClaude.path, home: host.home.path, localPort: 1, relayPort: 1)
        }
        let driver = AgentWorkflowDriver(runtime: harness.runtime)
        driver.gitProvider = { nil }
        driver.pollInterval = .milliseconds(20)
        let engine = RunEngine(database: harness.database, driver: driver)

        let task = try harness.database.insert(Chat(
            projectId: project.id!, title: "Add alpha and beta", body: "Two files, please.", source: .chat,
            status: .incoming, createdAt: .now, updatedAt: .now
        ))
        let run = try engine.start(task: task, workflow: try #require(ProjectConfigLoader.load(repository: project.filesRoot).workflow("feature-delivery")), project: project)

        try await waitUntil(timeout: .seconds(60)) { engine.holds[run.id!]?.reason == .planApproval || (try? harness.database.run(id: run.id!))??.status == .failed }
        #expect((try harness.database.run(id: run.id!))?.lastError == nil)
        let planStep = try harness.database.runSteps(runId: run.id!).first { $0.stepId == "plan" }
        let plan = try #require(planStep?.output.flatMap { try? JSONDecoder().decode(StepOutput.self, from: Data($0.utf8)) }?.plan)
        try engine.approvePlan(run, plan: plan)

        try await waitUntil(timeout: .seconds(90)) { engine.holds[run.id!]?.reason == .approval || (try? harness.database.run(id: run.id!))??.status == .failed }
        #expect((try harness.database.run(id: run.id!))?.lastError == nil)
        let steps = try harness.database.runSteps(runId: run.id!)
        #expect(steps.map(\.stepId) == ["plan", "build", "review", "qa", "approve"])

        let agents = try harness.database.agents(inProject: project.id!).filter { $0.runId == run.id }
        #expect(agents.allSatisfy { FileManager.default.fileExists(atPath: host.home.path + "/.cache/ensemble/agents/\($0.id!)/pid") })
        #expect(agents.compactMap(\.worktreePath).allSatisfy { $0.hasPrefix(root + "/.crew/") })
        let pins = try await harness.database.writer.read { db in try Pin.fetchAll(db) }
        #expect(Set(pins.map(\.file)) == ["alpha.txt", "beta.txt"])

        try engine.resolveApproval(run, approved: true)
        do {
            try await waitUntil(timeout: .seconds(30)) { (try? harness.database.run(id: run.id!))??.status == .succeeded }
        } catch {
            let final = try harness.database.run(id: run.id!)
            Issue.record("status=\(String(describing: final?.status)) error=\(String(describing: final?.lastError)) hold=\(String(describing: engine.holds[run.id!]))")
            throw error
        }
        let main = try await harness.repo.git.run(["ls-tree", "--name-only", "main"], in: harness.repo.root)
        #expect(main.contains("alpha.txt"))
        #expect(main.contains("beta.txt"))
        #expect(try await harness.repo.manager.list().isEmpty)
    }
}
