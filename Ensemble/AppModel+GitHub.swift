import AppKit
import EnsembleCore
import Foundation
import Observation

@MainActor
@Observable
final class GitHubConnection {
    var client: GitHubClient?
    @ObservationIgnored var startWorkflow: GitHubPoller.StartWorkflow = { _, _, _ in }
}

@MainActor
@Observable
final class GitHubIntegration {
    let auth: GitHubAuth
    let poller: GitHubPoller
    let writeBack: RunWriteBackObserver
    private let connection = GitHubConnection()

    private(set) var user: GitHubUser?
    private(set) var deviceCode: DeviceCode?
    private(set) var isSigningIn = false
    private(set) var signInError: String?
    private(set) var repositories: [GitHubRepository] = []

    @ObservationIgnored private var deviceFlow: Task<Void, Never>?

    init(engine: RunEngine, secrets: any SecretStore) {
        auth = GitHubAuth(bundle: .main, secrets: secrets)
        connection.client = try? auth.client()
        poller = GitHubPoller(
            database: engine.database,
            source: { [connection] in connection.client },
            startWorkflow: { [connection] task, mapping, project in
                try connection.startWorkflow(task, mapping, project)
            }
        )
        writeBack = RunWriteBackObserver(engine: engine) { [connection] in connection.client }
    }

    var client: GitHubClient? { connection.client }

    var startWorkflow: GitHubPoller.StartWorkflow {
        get { connection.startWorkflow }
        set { connection.startWorkflow = newValue }
    }

    var isSignedIn: Bool { client != nil }

    var isDeviceFlowAvailable: Bool { auth.isDeviceFlowAvailable }

    func start() {
        poller.start()
        writeBack.start()
        Task { await refreshUser() }
    }

    func refreshUser() async {
        guard let client else {
            user = nil
            return
        }
        do {
            user = try await client.currentUser()
        } catch GitHubError.unauthorized {
            user = nil
            signInError = GitHubError.unauthorized.localizedDescription
        } catch {
            signInError = error.localizedDescription
        }
    }

    func loadRepositories() async {
        guard let client, repositories.isEmpty else { return }
        repositories = (try? await client.repositories()) ?? []
    }

    func beginDeviceFlow() {
        guard deviceFlow == nil else { return }
        signInError = nil
        isSigningIn = true
        deviceFlow = Task { [weak self, auth] in
            do {
                let code = try await auth.startDeviceFlow()
                self?.deviceCode = code
                NSWorkspace.shared.open(code.verificationURI)
                try await auth.pollForToken(code)
                await self?.signedIn()
            } catch is CancellationError {
            } catch {
                self?.signInError = error.localizedDescription
            }
            self?.deviceCode = nil
            self?.isSigningIn = false
            self?.deviceFlow = nil
        }
    }

    func cancelDeviceFlow() {
        deviceFlow?.cancel()
    }

    func useToken(_ token: String) async {
        signInError = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            user = try await auth.useToken(token)
            connection.client = try auth.client()
            writeBack.requestSync()
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() {
        do {
            try auth.signOut()
        } catch {
            signInError = error.localizedDescription
        }
        connection.client = nil
        user = nil
        repositories = []
    }

    private func signedIn() async {
        connection.client = try? auth.client()
        writeBack.requestSync()
        await refreshUser()
    }
}

extension AppModel {
    func connectGitHub() {
        gitHub.startWorkflow = { [weak self] task, mapping, project in
            try self?.startMappedWorkflow(task: task, workflowID: mapping.workflow, in: project)
        }
    }

    func startMappedWorkflow(task: ProjectTask, workflowID: String, in project: Project) throws {
        guard let workflow = config(for: project).workflow(workflowID) else {
            throw GitHubSettingsError.unknownWorkflow(workflowID)
        }
        try ensureWithinBudget(project)
        try engine.start(task: task, workflow: workflow, project: project)
    }

    func checkGitHubNow(for project: Project) async -> String {
        do {
            let result = try await gitHub.poller.poll(project)
            switch (result.imported.count, result.autoStarted.count) {
            case (0, _): return "No new issues."
            case (let imported, 0): return "Imported \(imported) issue\(imported == 1 ? "" : "s")."
            case (let imported, let started): return "Imported \(imported), started \(started)."
            }
        } catch {
            return error.localizedDescription
        }
    }

    func originRepository(for project: Project) async -> String? {
        guard let git else { return nil }
        return try? await GitHubRemote.originRepository(in: project.url, git: git)
    }
}

enum GitHubSettingsError: LocalizedError {
    case unknownWorkflow(String)

    var errorDescription: String? {
        switch self {
        case .unknownWorkflow(let id): "There is no workflow “\(id)” in .ensemble/workflows/."
        }
    }
}
