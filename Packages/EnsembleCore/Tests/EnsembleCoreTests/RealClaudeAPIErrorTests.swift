import Foundation
import Testing
@testable import EnsembleCore

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENSEMBLE_REAL_CLAUDE"] == "1"), .serialized)
struct RealClaudeAPIErrorTests {
    struct StubAPILauncher: AgentProcessLauncher {
        let baseURL: String

        func launch(_ launch: ClaudeLaunch) throws -> (AgentProcessHandle, AsyncStream<ProcessOutput>) {
            var environment = launch.environment
            environment["ANTHROPIC_BASE_URL"] = baseURL
            environment["CLAUDE_CODE_MAX_RETRIES"] = "0"
            return try ClaudeProcessLauncher().launch(ClaudeLaunch(
                executable: launch.executable, worktree: launch.worktree, session: launch.session, model: launch.model,
                systemPrompt: launch.systemPrompt, environment: environment, readOnly: launch.readOnly,
                additionalDirectories: launch.additionalDirectories, extraArguments: launch.extraArguments,
                extraAllowedTools: launch.extraAllowedTools, hooks: launch.hooks
            ))
        }
    }

    static let stubServer = """
    import http.server, json, sys
    status = int(sys.argv[2])
    kind = {429: "rate_limit_error", 529: "overloaded_error", 401: "authentication_error"}[status]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("content-length", 0)))
            body = json.dumps({"type": "error", "error": {"type": kind, "message": "stub " + kind}}).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            self.do_POST()
        def log_message(self, *args):
            pass
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
    """

    func startStub(status: Int) throws -> (Process, String) {
        let port = Int.random(in: 20000...29999)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", Self.stubServer, String(port), String(status)]
        try process.run()
        Thread.sleep(forTimeInterval: 0.8)
        return (process, "http://127.0.0.1:\(port)")
    }

    func makeHarness(stubURL: String) async throws -> AgentHarness {
        let secrets = InMemorySecretStore()
        try secrets.write("sk-ant-stub", for: .anthropicAPIKey)
        let fake = try await AgentHarness.make(provider: .apiKey, secrets: secrets)
        let executable = ProcessInfo.processInfo.environment["ENSEMBLE_CLAUDE_PATH"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")
        let runtime = AgentRuntime(
            database: fake.database, paths: AppPaths(root: fake.data), secrets: secrets, providerMode: .apiKey,
            launcher: StubAPILauncher(baseURL: stubURL), claudeExecutable: executable,
            processEnvironment: ProcessInfo.processInfo.environment, stopGracePeriod: .seconds(2)
        )
        return AgentHarness(repo: fake.repo, bin: fake.bin, data: fake.data, database: fake.database, runtime: runtime, project: fake.project)
    }

    @Test(.timeLimit(.minutes(3))) func realClaudeRateLimitsAreRetriedThenReported() async throws {
        let (stub, url) = try startStub(status: 429)
        defer { stub.terminate() }
        let harness = try await makeHarness(stubURL: url)
        defer { harness.cleanUp() }
        harness.runtime.apiRetryDelays = [.milliseconds(500)]

        let session = try await harness.spawn()
        try await waitUntil(timeout: .seconds(90)) { session.retryingAt != nil }
        try await waitUntil(timeout: .seconds(90)) { session.agent.status == .failed }

        let notices = session.transcript.entries.compactMap { entry -> EnsembleNotice? in
            if case .notice(let notice, _) = entry.content { return notice }
            return nil
        }
        #expect(notices.filter { $0 == .retrying }.count == 1)
        #expect(session.agent.lastError?.hasPrefix("The Claude API rate limit was reached, and 1 retries didn’t get through.") == true)
    }

    @Test(.timeLimit(.minutes(3))) func realClaudeAuthenticationErrorsFailWithoutRetrying() async throws {
        let (stub, url) = try startStub(status: 401)
        defer { stub.terminate() }
        let harness = try await makeHarness(stubURL: url)
        defer { harness.cleanUp() }
        harness.runtime.apiRetryDelays = [.milliseconds(500)]

        let session = try await harness.spawn()
        try await waitUntil(timeout: .seconds(90)) { session.agent.status == .failed }
        #expect(session.agent.lastError?.hasPrefix("Claude rejected the credentials.") == true)
        #expect(!harness.runtime.isCoolingDown)
    }
}
