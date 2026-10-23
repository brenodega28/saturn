import Foundation
import Synchronization
import Testing
@testable import EnsembleCore

final class ManualClock: Sendable {
    private let state = Mutex<(now: Date, sleeps: [Duration])>((Date(timeIntervalSince1970: 1_000_000), []))

    var now: Date { state.withLock { $0.now } }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func sleep(_ duration: Duration) {
        state.withLock { state in
            state.sleeps.append(duration)
            state.now = state.now.addingTimeInterval(TimeInterval(duration.components.seconds))
        }
    }
}

@Suite struct GitHubAuthTests {
    let stub = HTTPStub()
    let clock = ManualClock()
    let secrets = InMemorySecretStore()

    func makeAuth(clientID: String? = "Iv1.client") -> GitHubAuth {
        let clock = clock
        return GitHubAuth(
            clientID: clientID,
            secrets: secrets,
            session: stub.session,
            sleep: { clock.sleep($0) },
            now: { clock.now }
        )
    }

    func deviceCode(interval: Int = 5, expiresIn: TimeInterval = 900) -> DeviceCode {
        DeviceCode(
            deviceCode: "dev-code",
            userCode: "ABCD-1234",
            verificationURI: URL(fileURLWithPath: "/login/device"),
            interval: interval,
            expiresAt: clock.now.addingTimeInterval(expiresIn)
        )
    }

    @Test func deviceFlowAvailabilityFollowsClientID() {
        #expect(makeAuth().isDeviceFlowAvailable)
        #expect(!makeAuth(clientID: nil).isDeviceFlowAvailable)
        #expect(!makeAuth(clientID: "  ").isDeviceFlowAvailable)
    }

    @Test func readsClientIDFromInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ensemble-bundles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func bundle(withClientID clientID: String?) throws -> Bundle {
            let bundleURL = root.appending(path: "\(UUID().uuidString).bundle")
            let contents = bundleURL.appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)"]
            info[GitHubAuth.clientIDInfoKey] = clientID
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
            return try #require(Bundle(path: bundleURL.path))
        }

        #expect(GitHubAuth.clientID(in: try bundle(withClientID: " Iv1.abc ")) == "Iv1.abc")
        #expect(GitHubAuth.clientID(in: try bundle(withClientID: "")) == nil)
        #expect(GitHubAuth.clientID(in: try bundle(withClientID: "$(GITHUB_CLIENT_ID)")) == nil)
        #expect(GitHubAuth.clientID(in: try bundle(withClientID: nil)) == nil)
        #expect(GitHubAuth(bundle: try bundle(withClientID: "Iv1.abc"), secrets: secrets).isDeviceFlowAvailable)
        #expect(!GitHubAuth(bundle: try bundle(withClientID: ""), secrets: secrets).isDeviceFlowAvailable)
    }

    @Test func startsDeviceFlow() async throws {
        stub.enqueue(.json(#"{"device_code": "dev-code", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5}"#))

        let code = try await makeAuth().startDeviceFlow()

        #expect(code.deviceCode == "dev-code")
        #expect(code.userCode == "ABCD-1234")
        #expect(code.verificationURI.absoluteString == "https://github.com/login/device")
        #expect(code.interval == 5)
        #expect(code.expiresAt == clock.now.addingTimeInterval(900))
        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://github.com/login/device/code")
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.formBody() == ["client_id": "Iv1.client", "scope": "repo"])
    }

    @Test func startDeviceFlowWithoutClientIDFails() async {
        await #expect(throws: GitHubAuthError.deviceFlowUnavailable) { try await makeAuth(clientID: nil).startDeviceFlow() }
        #expect(stub.requests.isEmpty)
    }

    @Test func startDeviceFlowSurfacesOAuthErrors() async {
        stub.enqueue(.json(#"{"error": "device_flow_disabled", "error_description": "Device flow is disabled for this app"}"#))

        await #expect(throws: GitHubAuthError.oauth(code: "device_flow_disabled", description: "Device flow is disabled for this app")) {
            try await makeAuth().startDeviceFlow(clientID: "other", scopes: ["repo", "read:org"])
        }
        #expect(stub.requests.first?.formBody() == ["client_id": "other", "scope": "repo read:org"])
    }

    @Test func pollsThroughPendingAndSlowDownToToken() async throws {
        stub.enqueue(
            .json(#"{"error": "authorization_pending"}"#),
            .json(#"{"error": "slow_down", "interval": 10}"#),
            .json(#"{"error": "authorization_pending"}"#),
            .json(#"{"access_token": "gho_token", "token_type": "bearer", "scope": "repo"}"#)
        )

        let token = try await makeAuth().pollForToken(deviceCode())

        #expect(token == "gho_token")
        #expect(clock.sleeps == [.seconds(5), .seconds(5), .seconds(10), .seconds(10)])
        #expect(try secrets.read(.githubToken) == "gho_token")
        #expect(stub.requests.count == 4)
        let poll = try #require(stub.requests.last)
        #expect(poll.url.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(poll.formBody() == [
            "client_id": "Iv1.client",
            "device_code": "dev-code",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
    }

    @Test func slowDownAddsFiveSecondsWithoutServerInterval() async throws {
        stub.enqueue(
            .json(#"{"error": "slow_down"}"#),
            .json(#"{"error": "slow_down"}"#),
            .json(#"{"access_token": "gho_token"}"#)
        )

        _ = try await makeAuth().pollForToken(deviceCode(interval: 5))

        #expect(clock.sleeps == [.seconds(5), .seconds(10), .seconds(15)])
    }

    @Test func pollingStopsOnExpiredToken() async throws {
        stub.enqueue(.json(#"{"error": "authorization_pending"}"#), .json(#"{"error": "expired_token"}"#))

        await #expect(throws: GitHubAuthError.expiredToken) { try await makeAuth().pollForToken(deviceCode()) }
        #expect(try secrets.read(.githubToken) == nil)
    }

    @Test func pollingStopsWhenCodeExpiresLocally() async throws {
        stub.enqueue(.json(#"{"error": "authorization_pending"}"#), .json(#"{"error": "authorization_pending"}"#))

        await #expect(throws: GitHubAuthError.expiredToken) {
            try await makeAuth().pollForToken(deviceCode(interval: 5, expiresIn: 12))
        }
        #expect(stub.requests.count == 2)
    }

    @Test func pollingStopsOnAccessDenied() async {
        stub.enqueue(.json(#"{"error": "access_denied"}"#))

        await #expect(throws: GitHubAuthError.accessDenied) { try await makeAuth().pollForToken(deviceCode()) }
    }

    @Test func pollingIsCancellable() async throws {
        let auth = GitHubAuth(clientID: "Iv1.client", secrets: secrets, session: stub.session, sleep: { _ in
            throw CancellationError()
        })

        await #expect(throws: CancellationError.self) { try await auth.pollForToken(deviceCode()) }
        #expect(stub.requests.isEmpty)
    }

    @Test func personalAccessTokenIsValidatedBeforeStoring() async throws {
        stub.enqueue(.json(401, #"{"message": "Bad credentials"}"#), .json(GitHubFixtures.user))
        let auth = makeAuth()

        await #expect(throws: GitHubError.unauthorized) { try await auth.useToken("bad") }
        #expect(try secrets.read(.githubToken) == nil)
        #expect(!auth.isSignedIn)

        let user = try await auth.useToken("  ghp_good\n")

        #expect(user.login == "octocat")
        #expect(try auth.storedToken() == "ghp_good")
        #expect(auth.isSignedIn)
        #expect(stub.requests.map { $0.header("Authorization") } == ["Bearer bad", "Bearer ghp_good"])
        #expect(stub.requests[1].url.absoluteString == "https://api.github.com/user")
        #expect(try auth.client()?.token == "ghp_good")
    }

    @Test func emptyTokenIsRejectedWithoutNetwork() async {
        await #expect(throws: GitHubError.unauthorized) { try await makeAuth().useToken("   ") }
        #expect(stub.requests.isEmpty)
    }

    @Test func signOutDeletesToken() throws {
        try secrets.write("ghp_x", for: .githubToken)
        let auth = makeAuth()
        #expect(auth.isSignedIn)

        try auth.signOut()

        #expect(try secrets.read(.githubToken) == nil)
        #expect(try auth.client().map(\.token) == nil)
    }
}
