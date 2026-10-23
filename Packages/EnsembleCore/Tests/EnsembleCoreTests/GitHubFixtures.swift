import Foundation

enum GitHubFixtures {
    static let user = #"{"id": 7, "login": "octocat", "name": "The Octocat", "avatar_url": "https://avatars.example/7"}"#

    static func repository(id: Int = 1, fullName: String = "octo/widgets", isPrivate: Bool = true) -> String {
        let parts = fullName.split(separator: "/")
        return """
        {"id": \(id), "name": "\(parts[1])", "full_name": "\(fullName)", "owner": {"login": "\(parts[0])"},
         "private": \(isPrivate), "default_branch": "main", "html_url": "https://github.com/\(fullName)",
         "description": null}
        """
    }

    static func issue(number: Int, labels: [String] = [], isPullRequest: Bool = false) -> String {
        let labelJSON = labels.map { #"{"name": "\#($0)", "color": "ededed"}"# }.joined(separator: ",")
        let pullRequest = isPullRequest ? #", "pull_request": {"url": "https://api.github.com/x"}"# : ""
        return """
        {"id": \(1000 + number), "number": \(number), "title": "Issue \(number)", "body": "Body \(number)",
         "state": "open", "html_url": "https://github.com/octo/widgets/issues/\(number)",
         "labels": [\(labelJSON)], "user": {"login": "octocat"},
         "created_at": "2026-10-01T12:00:00Z", "updated_at": "2026-10-02T08:30:00Z"\(pullRequest)}
        """
    }

    static func label(_ name: String, color: String = "fbca04") -> String {
        #"{"name": "\#(name)", "color": "\#(color)", "description": null}"#
    }

    static func comment(id: Int = 55, body: String = "hi") -> String {
        #"{"id": \#(id), "body": "\#(body)", "html_url": "https://github.com/octo/widgets/issues/1#issuecomment-\#(id)"}"#
    }

    static func pullRequest(number: Int = 9, head: String = "crew/dev/fix", draft: Bool = true) -> String {
        """
        {"id": 900, "number": \(number), "title": "Fix", "body": "Closes #1", "state": "open", "draft": \(draft),
         "html_url": "https://github.com/octo/widgets/pull/\(number)",
         "head": {"ref": "\(head)", "sha": "abc"}, "base": {"ref": "main", "sha": "def"}}
        """
    }
}
