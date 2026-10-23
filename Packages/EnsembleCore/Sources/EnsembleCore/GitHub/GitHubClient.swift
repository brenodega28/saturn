import Foundation

public struct GitHubClient: Sendable {
    public static let apiHost = "api.github.com"
    public static let apiVersion = "2022-11-28"
    public static let mediaType = "application/vnd.github+json"

    public let token: String
    public let host: String
    public let maximumPages: Int
    private let session: URLSession

    public init(token: String, session: URLSession = .shared, host: String = GitHubClient.apiHost, maximumPages: Int = 50) {
        self.token = token
        self.session = session
        self.host = host
        self.maximumPages = maximumPages
    }

    public func currentUser() async throws -> GitHubUser {
        try await send(.get, ["user"])
    }

    public func repository(_ repository: String) async throws -> GitHubRepository {
        try await send(.get, Self.repositoryPath(repository))
    }

    public func repositories() async throws -> [GitHubRepository] {
        try await paged(["user", "repos"], query: [
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ])
    }

    public func openIssues(in repository: String, label: String? = nil) async throws -> [GitHubIssue] {
        var query = [URLQueryItem(name: "state", value: "open")]
        if let label {
            query.append(URLQueryItem(name: "labels", value: label))
        }
        let issues: [GitHubIssue] = try await paged(Self.repositoryPath(repository) + ["issues"], query: query)
        return issues.filter { !$0.isPullRequest }
    }

    public func issue(_ number: Int, in repository: String) async throws -> GitHubIssue {
        try await send(.get, Self.repositoryPath(repository) + ["issues", String(number)])
    }

    @discardableResult
    public func addLabels(_ labels: [String], toIssue number: Int, in repository: String) async throws -> [GitHubLabel] {
        try await send(
            .post,
            Self.repositoryPath(repository) + ["issues", String(number), "labels"],
            body: try Self.encode(["labels": labels])
        )
    }

    public func removeLabel(_ label: String, fromIssue number: Int, in repository: String) async throws {
        do {
            try await sendIgnoringResponse(.delete, Self.repositoryPath(repository) + ["issues", String(number), "labels", label])
        } catch GitHubError.notFound {
            return
        }
    }

    public func label(_ name: String, in repository: String) async throws -> GitHubLabel? {
        do {
            let label: GitHubLabel = try await send(.get, Self.repositoryPath(repository) + ["labels", name])
            return label
        } catch GitHubError.notFound {
            return nil
        }
    }

    @discardableResult
    public func ensureLabel(
        _ name: String, color: String, description: String? = nil, in repository: String
    ) async throws -> GitHubLabel {
        if let existing = try await label(name, in: repository) {
            return existing
        }
        let newLabel = GitHubLabel(name: name, color: Self.normalizedColor(color), description: description)
        do {
            return try await send(.post, Self.repositoryPath(repository) + ["labels"], body: try Self.encode(newLabel))
        } catch GitHubError.validation {
            if let existing = try await label(name, in: repository) {
                return existing
            }
            throw GitHubError.validation(message: "Could not create label \(name)")
        }
    }

    @discardableResult
    public func createComment(_ body: String, onIssue number: Int, in repository: String) async throws -> GitHubComment {
        try await send(
            .post,
            Self.repositoryPath(repository) + ["issues", String(number), "comments"],
            body: try Self.encode(["body": body])
        )
    }

    public func createPullRequest(_ pullRequest: NewPullRequest, in repository: String) async throws -> GitHubPullRequest {
        try await send(.post, Self.repositoryPath(repository) + ["pulls"], body: try Self.encode(pullRequest))
    }

    public func pullRequest(
        forHead branch: String, in repository: String, state: GitHubPullRequestState = .open
    ) async throws -> GitHubPullRequest? {
        let path = try Self.repositoryPath(repository)
        let owner = path[1]
        let head = branch.contains(":") ? branch : "\(owner):\(branch)"
        let pulls: [GitHubPullRequest] = try await send(.get, path + ["pulls"], query: [
            URLQueryItem(name: "head", value: head),
            URLQueryItem(name: "state", value: state.rawValue),
        ])
        return pulls.first
    }
}

extension GitHubClient {
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    static func repositoryPath(_ repository: String) throws -> [String] {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }) else {
            throw GitHubError.invalidRepository(repository)
        }
        return ["repos", parts[0], parts[1]]
    }

    static func normalizedColor(_ color: String) -> String {
        color.hasPrefix("#") ? String(color.dropFirst()) : color
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    func url(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/" + path.map(GitHubURLEncoding.pathSegment).joined(separator: "/")
        if !query.isEmpty {
            components.percentEncodedQuery = GitHubURLEncoding.query(query)
        }
        guard let url = components.url else { throw GitHubError.invalidResponse }
        return url
    }

    func request(_ method: Method, url: URL, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(Self.mediaType, forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Ensemble", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, data: data)
        }
        return (data, http)
    }

    func send<Response: Decodable>(
        _ method: Method, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil
    ) async throws -> Response {
        let (data, _) = try await perform(request(method, url: url(path, query: query), body: body))
        return try Self.decode(Response.self, from: data)
    }

    func sendIgnoringResponse(_ method: Method, _ path: [String], body: Data? = nil) async throws {
        _ = try await perform(request(method, url: url(path), body: body))
    }

    func paged<Element: Decodable>(_ path: [String], query: [URLQueryItem] = []) async throws -> [Element] {
        var nextURL: URL? = try url(path, query: query + [URLQueryItem(name: "per_page", value: "100")])
        var elements: [Element] = []
        var pagesFetched = 0
        while let pageURL = nextURL, pagesFetched < maximumPages {
            let (data, response) = try await perform(request(.get, url: pageURL))
            elements += try Self.decode([Element].self, from: data)
            pagesFetched += 1
            nextURL = Self.nextPageURL(fromLinkHeader: response.value(forHTTPHeaderField: "Link"))
                .flatMap { $0.host == host ? $0 : nil }
        }
        return elements
    }

    static func nextPageURL(fromLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = parts.dropFirst().contains { parameter in
                let pair = parameter.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                return pair.count == 2 && pair[0] == "rel" && pair[1].split(separator: " ").contains("next")
            }
            if isNext {
                return URL(string: String(target.dropFirst().dropLast()))
            }
        }
        return nil
    }

    static func error(for response: HTTPURLResponse, data: Data, now: Date = Date()) -> GitHubError {
        let body = try? decoder.decode(GitHubErrorBody.self, from: data)
        let message = body?.message ?? ""
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 422:
            return .validation(message: body?.validationSummary ?? message)
        case 403, 429:
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(TimeInterval.init)
                    .map(Date.init(timeIntervalSince1970:))
                return .rateLimited(resetAt: reset)
            }
            if let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init) {
                return .rateLimited(resetAt: now.addingTimeInterval(retryAfter))
            }
            if response.statusCode == 429 || message.localizedCaseInsensitiveContains("rate limit") {
                return .rateLimited(resetAt: nil)
            }
            return .http(status: response.statusCode, message: message)
        default:
            return .http(status: response.statusCode, message: message)
        }
    }
}

struct GitHubErrorBody: Decodable {
    struct Detail: Decodable {
        var resource: String?
        var field: String?
        var code: String?
        var message: String?

        var summary: String {
            if let message, !message.isEmpty { return message }
            return [resource, field, code].compactMap(\.self).joined(separator: " ")
        }
    }

    var message: String?
    var errors: [Detail]?

    var validationSummary: String {
        let details = (errors ?? []).map(\.summary).filter { !$0.isEmpty }
        let headline = message ?? "Validation failed"
        return details.isEmpty ? headline : "\(headline): \(details.joined(separator: "; "))"
    }
}

enum GitHubURLEncoding {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let pathAllowed = unreserved.union(CharacterSet(charactersIn: ":@!$&'()*+,;="))

    static func pathSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? segment
    }

    static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func query(_ items: [URLQueryItem]) -> String {
        items.map { "\(component($0.name))=\(component($0.value ?? ""))" }.joined(separator: "&")
    }
}
