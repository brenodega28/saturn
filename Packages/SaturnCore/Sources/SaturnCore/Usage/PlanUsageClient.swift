import Foundation
import Security

public protocol PlanUsageCredentialSource: Sendable {
    func accessToken() throws -> String?
}

public struct ClaudeCodeKeychainCredentials: PlanUsageCredentialSource {
    public static let service = "Claude Code-credentials"

    public init() {}

    public func accessToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? Data).flatMap(Self.accessToken(fromCredentials:))
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    static func accessToken(fromCredentials data: Data) -> String? {
        struct Credentials: Decodable {
            struct OAuth: Decodable {
                var accessToken: String?
            }

            var claudeAiOauth: OAuth?
        }
        let token = (try? JSONDecoder().decode(Credentials.self, from: data))?.claudeAiOauth?.accessToken
        return token.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct PlanUsageClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    private let token: String
    private let transport: Transport
    private let now: @Sendable () -> Date

    public init(
        token: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.token = token
        self.transport = transport
        self.now = now
    }

    public func fetch() async throws -> PlanUsage {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request())
        } catch {
            throw PlanUsageError.failed("Couldn’t reach Claude to check plan usage.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw PlanUsageError.failed("Claude returned a response Saturn could not read.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, now: now())
        }
        return try PlanUsage.parse(data)
    }

    func request() -> URLRequest {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Saturn", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func error(for response: HTTPURLResponse, now: Date) -> PlanUsageError {
        switch response.statusCode {
        case 401, 403:
            return .unauthorized
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            return .rateLimited(resetAt: retryAfter.map { now.addingTimeInterval($0) })
        default:
            return .failed("Claude returned HTTP \(response.statusCode) for plan usage.")
        }
    }
}
