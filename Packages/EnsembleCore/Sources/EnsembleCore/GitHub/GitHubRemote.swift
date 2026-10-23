import Foundation

public enum GitHubRemote {
    public static let defaultHosts: Set<String> = ["github.com", "www.github.com"]

    public static func parse(_ remoteURL: String, hosts: Set<String> = defaultHosts) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (host, path) = hostAndPath(of: trimmed) else { return nil }
        guard hosts.contains(host.lowercased()) else { return nil }
        return repositoryName(fromPath: path)
    }

    public static func originRepository(in directory: URL, git: GitClient, hosts: Set<String> = defaultHosts) async throws -> String? {
        let remote: String
        do {
            remote = try await git.run(["remote", "get-url", "origin"], in: directory)
        } catch is CommandError {
            return nil
        }
        return parse(remote, hosts: hosts)
    }

    private static func hostAndPath(of remote: String) -> (String, String)? {
        if remote.contains("://") {
            guard let components = URLComponents(string: remote),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let host = components.host, !host.isEmpty
            else { return nil }
            return (host, components.path)
        }
        guard let colon = remote.firstIndex(of: ":") else { return nil }
        let authority = remote[..<colon]
        let path = remote[remote.index(after: colon)...]
        guard !authority.contains("/") else { return nil }
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard !host.isEmpty else { return nil }
        return (host, String(path))
    }

    private static func repositoryName(fromPath path: String) -> String? {
        var segments = path.split(separator: "/").map(String.init)
        guard segments.count == 2 else { return nil }
        if segments[1].lowercased().hasSuffix(".git") {
            segments[1] = String(segments[1].dropLast(4))
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard segments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return nil
        }
        return segments.joined(separator: "/")
    }
}
