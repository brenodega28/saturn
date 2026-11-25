import Foundation

public struct ClaudeAPIError: Sendable, Hashable {
    public var kind: String
    public var status: Int?
    public var message: String

    public init(kind: String, status: Int? = nil, message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }

    public var isTransient: Bool {
        switch kind {
        case "authentication_failed", "billing_error", "invalid_request": return false
        case "rate_limit", "server_error": return true
        default: break
        }
        guard let status else { return true }
        return [408, 429, 529].contains(status) || (500...599).contains(status)
    }

    public var isRateLimit: Bool { kind == "rate_limit" || status == 429 }

    public var summary: String {
        if isRateLimit { return "The Claude API rate limit was reached" }
        if isTransient { return "The Claude API was unavailable" }
        switch kind {
        case "authentication_failed": return "Claude rejected the credentials"
        case "billing_error": return "Claude refused the request for a billing reason"
        default: return "Claude rejected the request"
        }
    }
}

public struct APIRetry: Sendable, Hashable {
    public let attempt: Int
    public let maxRetries: Int
    public let delayMS: Int
    public let status: Int?
    public let error: String?
}
