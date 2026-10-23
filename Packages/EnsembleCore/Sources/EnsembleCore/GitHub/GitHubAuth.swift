import Foundation

public struct DeviceCode: Codable, Sendable, Hashable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var interval: Int
    public var expiresAt: Date

    public init(deviceCode: String, userCode: String, verificationURI: URL, interval: Int, expiresAt: Date) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.interval = interval
        self.expiresAt = expiresAt
    }
}

public struct GitHubAuth: Sendable {
    public static let clientIDInfoKey = "GitHubClientID"
    public static let defaultScopes = ["repo"]
    public static let webHost = "github.com"
    public static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    public static let slowDownIncrement = 5

    public let clientID: String?
    private let secrets: any SecretStore
    private let session: URLSession
    private let apiHost: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        clientID: String?,
        secrets: any SecretStore,
        session: URLSession = .shared,
        apiHost: String = GitHubClient.apiHost,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = trimmed?.isEmpty == false ? trimmed : nil
        self.secrets = secrets
        self.session = session
        self.apiHost = apiHost
        self.sleep = sleep
        self.now = now
    }

    public init(bundle: Bundle = .main, secrets: any SecretStore, session: URLSession = .shared) {
        self.init(clientID: Self.clientID(in: bundle), secrets: secrets, session: session)
    }

    public static func clientID(in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: clientIDInfoKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    public var isDeviceFlowAvailable: Bool { clientID != nil }

    public var isSignedIn: Bool { (try? storedToken()) != nil }

    public func storedToken() throws -> String? {
        try secrets.read(.githubToken).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func client() throws -> GitHubClient? {
        try storedToken().map { GitHubClient(token: $0, session: session, host: apiHost) }
    }

    public func signOut() throws {
        try secrets.delete(.githubToken)
    }

    @discardableResult
    public func useToken(_ token: String) async throws -> GitHubUser {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.unauthorized }
        let user = try await GitHubClient(token: trimmed, session: session, host: apiHost).currentUser()
        try secrets.write(trimmed, for: .githubToken)
        return user
    }

    public func startDeviceFlow(scopes: [String] = GitHubAuth.defaultScopes) async throws -> DeviceCode {
        guard let clientID else { throw GitHubAuthError.deviceFlowUnavailable }
        return try await startDeviceFlow(clientID: clientID, scopes: scopes)
    }

    public func startDeviceFlow(clientID: String, scopes: [String] = GitHubAuth.defaultScopes) async throws -> DeviceCode {
        let response: DeviceCodeResponse = try await post(
            path: "/login/device/code",
            form: ["client_id": clientID, "scope": scopes.joined(separator: " ")]
        )
        if let error = response.error {
            throw Self.authError(code: error, description: response.errorDescription)
        }
        guard let deviceCode = response.deviceCode, let userCode = response.userCode,
              let verificationURI = response.verificationURI, let expiresIn = response.expiresIn
        else { throw GitHubError.invalidResponse }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            interval: response.interval ?? 5,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    @discardableResult
    public func pollForToken(_ code: DeviceCode) async throws -> String {
        guard let clientID else { throw GitHubAuthError.deviceFlowUnavailable }
        return try await pollForToken(clientID: clientID, deviceCode: code)
    }

    @discardableResult
    public func pollForToken(clientID: String, deviceCode code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 1)
        while true {
            try await sleep(.seconds(interval))
            guard now() < code.expiresAt else { throw GitHubAuthError.expiredToken }
            let response: AccessTokenResponse = try await post(
                path: "/login/oauth/access_token",
                form: ["client_id": clientID, "device_code": code.deviceCode, "grant_type": Self.deviceGrantType]
            )
            if let token = response.accessToken, !token.isEmpty {
                try secrets.write(token, for: .githubToken)
                return token
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + Self.slowDownIncrement, response.interval ?? 0)
            case let error?:
                throw Self.authError(code: error, description: response.errorDescription)
            case nil:
                throw GitHubError.invalidResponse
            }
        }
    }

    static func authError(code: String, description: String?) -> GitHubAuthError {
        switch code {
        case "expired_token": .expiredToken
        case "access_denied": .accessDenied
        default: .oauth(code: code, description: description)
        }
    }

    private func post<Response: OAuthResponse>(path: String, form: [String: String]) async throws -> Response {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webHost
        components.path = path
        guard let url = components.url else { throw GitHubError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Ensemble", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(
            form.sorted { $0.key < $1.key }
                .map { "\(GitHubURLEncoding.component($0.key))=\(GitHubURLEncoding.component($0.value))" }
                .joined(separator: "&")
                .utf8
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        if let decoded, (200..<300).contains(http.statusCode) || decoded.error != nil {
            return decoded
        }
        guard (200..<300).contains(http.statusCode) else { throw GitHubClient.error(for: http, data: data) }
        throw GitHubError.invalidResponse
    }
}

protocol OAuthResponse: Decodable {
    var error: String? { get }
}

struct DeviceCodeResponse: OAuthResponse {
    var deviceCode: String?
    var userCode: String?
    var verificationURI: URL?
    var expiresIn: Int?
    var interval: Int?
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case interval, error
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case errorDescription = "error_description"
    }
}

struct AccessTokenResponse: OAuthResponse {
    var accessToken: String?
    var tokenType: String?
    var scope: String?
    var interval: Int?
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case scope, interval, error
        case accessToken = "access_token"
        case tokenType = "token_type"
        case errorDescription = "error_description"
    }
}
