import Foundation

public enum GitHubError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case notFound
    case rateLimited(resetAt: Date?)
    case validation(message: String)
    case http(status: Int, message: String)
    case invalidRepository(String)
    case invalidResponse
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "GitHub rejected the token. Sign in to GitHub again."
        case .notFound:
            "GitHub could not find that resource, or the token cannot see it."
        case .rateLimited(let resetAt):
            if let resetAt {
                "GitHub rate limit reached. It resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub rate limit reached. Try again shortly."
            }
        case .validation(let message):
            "GitHub rejected the request: \(message)"
        case .http(let status, let message):
            message.isEmpty ? "GitHub returned HTTP \(status)." : "GitHub returned HTTP \(status): \(message)"
        case .invalidRepository(let name):
            "\"\(name)\" is not an owner/repo name."
        case .invalidResponse:
            "GitHub returned a response Ensemble could not read."
        case .decoding(let detail):
            "GitHub returned unexpected data: \(detail)"
        }
    }
}

public enum GitHubAuthError: Error, Sendable, Equatable, LocalizedError {
    case deviceFlowUnavailable
    case expiredToken
    case accessDenied
    case oauth(code: String, description: String?)

    public var errorDescription: String? {
        switch self {
        case .deviceFlowUnavailable:
            "GitHub sign-in is not configured in this build. Use a personal access token instead."
        case .expiredToken:
            "The GitHub sign-in code expired. Start again."
        case .accessDenied:
            "GitHub sign-in was cancelled."
        case .oauth(let code, let description):
            description.map { "GitHub sign-in failed: \($0)" } ?? "GitHub sign-in failed (\(code))."
        }
    }
}
