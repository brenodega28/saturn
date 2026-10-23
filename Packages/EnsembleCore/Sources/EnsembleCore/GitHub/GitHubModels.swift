import Foundation

public struct GitHubUser: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var login: String
    public var name: String?
    public var avatarURL: URL?

    public init(id: Int, login: String, name: String? = nil, avatarURL: URL? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarURL = "avatar_url"
    }
}

public struct GitHubAccount: Codable, Sendable, Hashable {
    public var login: String

    public init(login: String) {
        self.login = login
    }
}

public struct GitHubRepository: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var fullName: String
    public var owner: GitHubAccount
    public var isPrivate: Bool
    public var defaultBranch: String
    public var htmlURL: URL
    public var description: String?

    public init(
        id: Int, name: String, fullName: String, owner: GitHubAccount, isPrivate: Bool,
        defaultBranch: String, htmlURL: URL, description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.owner = owner
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
        self.htmlURL = htmlURL
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner, description
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
    }
}

public struct GitHubLabel: Codable, Sendable, Hashable {
    public var name: String
    public var color: String
    public var description: String?

    public init(name: String, color: String, description: String? = nil) {
        self.name = name
        self.color = color
        self.description = description
    }
}

public struct GitHubIssue: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var number: Int
    public var title: String
    public var body: String?
    public var state: String
    public var htmlURL: URL
    public var labels: [GitHubLabel]
    public var user: GitHubAccount?
    public var createdAt: Date
    public var updatedAt: Date
    public var isPullRequest: Bool

    public init(
        id: Int, number: Int, title: String, body: String? = nil, state: String = "open", htmlURL: URL,
        labels: [GitHubLabel] = [], user: GitHubAccount? = nil, createdAt: Date, updatedAt: Date,
        isPullRequest: Bool = false
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.htmlURL = htmlURL
        self.labels = labels
        self.user = user
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPullRequest = isPullRequest
    }

    public var labelNames: [String] { labels.map(\.name) }

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, labels, user
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    private struct PullRequestMarker: Codable {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        state = try container.decode(String.self, forKey: .state)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        labels = try container.decodeIfPresent([GitHubLabel].self, forKey: .labels) ?? []
        user = try container.decodeIfPresent(GitHubAccount.self, forKey: .user)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPullRequest = try container.contains(.pullRequest) && !container.decodeNil(forKey: .pullRequest)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encode(state, forKey: .state)
        try container.encode(htmlURL, forKey: .htmlURL)
        try container.encode(labels, forKey: .labels)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        if isPullRequest {
            try container.encode(PullRequestMarker(), forKey: .pullRequest)
        }
    }
}

public struct GitHubComment: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var body: String
    public var htmlURL: URL

    public init(id: Int, body: String, htmlURL: URL) {
        self.id = id
        self.body = body
        self.htmlURL = htmlURL
    }

    enum CodingKeys: String, CodingKey {
        case id, body
        case htmlURL = "html_url"
    }
}

public struct GitHubBranchRef: Codable, Sendable, Hashable {
    public var ref: String
    public var sha: String?

    public init(ref: String, sha: String? = nil) {
        self.ref = ref
        self.sha = sha
    }
}

public struct GitHubPullRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var number: Int
    public var title: String
    public var body: String?
    public var state: String
    public var isDraft: Bool
    public var htmlURL: URL
    public var head: GitHubBranchRef
    public var base: GitHubBranchRef

    public init(
        id: Int, number: Int, title: String, body: String? = nil, state: String = "open", isDraft: Bool = false,
        htmlURL: URL, head: GitHubBranchRef, base: GitHubBranchRef
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.isDraft = isDraft
        self.htmlURL = htmlURL
        self.head = head
        self.base = base
    }

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, head, base
        case isDraft = "draft"
        case htmlURL = "html_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        state = try container.decode(String.self, forKey: .state)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        head = try container.decode(GitHubBranchRef.self, forKey: .head)
        base = try container.decode(GitHubBranchRef.self, forKey: .base)
    }
}

public struct NewPullRequest: Codable, Sendable, Hashable {
    public var title: String
    public var head: String
    public var base: String
    public var body: String?
    public var draft: Bool

    public init(title: String, head: String, base: String, body: String? = nil, draft: Bool = false) {
        self.title = title
        self.head = head
        self.base = base
        self.body = body
        self.draft = draft
    }
}

public enum GitHubPullRequestState: String, Sendable, Hashable, CaseIterable {
    case open
    case closed
    case all
}
