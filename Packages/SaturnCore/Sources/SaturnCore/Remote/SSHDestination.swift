import Foundation

public enum SSHDestinationError: Error, LocalizedError, Equatable {
    case empty
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a host, such as an alias from ~/.ssh/config or user@host."
        case .invalid(let value): "“\(value)” isn’t a host ssh can connect to."
        }
    }
}

public enum SSHDestination {
    public static func normalize(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SSHDestinationError.empty }
        guard !value.hasPrefix("-"), !value.contains(where: \.isWhitespace) else { throw SSHDestinationError.invalid(value) }
        if value.hasPrefix("ssh://") {
            guard value.count > "ssh://".count else { throw SSHDestinationError.invalid(value) }
            return value
        }
        guard let colon = value.lastIndex(of: ":") else { return value }
        let host = value[..<colon]
        let port = value[value.index(after: colon)...]
        guard !host.isEmpty, !host.contains(":"), !port.isEmpty, port.allSatisfy(\.isASCIIDigit) else {
            throw SSHDestinationError.invalid(value)
        }
        return "ssh://\(value)"
    }

    public static func displayName(_ destination: String) -> String {
        destination.hasPrefix("ssh://") ? String(destination.dropFirst("ssh://".count)) : destination
    }
}

public enum SSHConfigHosts {
    static let maximumIncludeDepth = 16

    public static func parse(_ contents: String, includes: (String) -> [String] = { _ in [] }) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        collect(contents, includes: includes, depth: 0, seen: &seen, hosts: &hosts)
        return hosts
    }

    public static func load(
        from file: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config"),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(contents) { pattern in
            expand(pattern, home: home).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    static func expand(_ pattern: String, home: URL) -> [String] {
        let absolute: String
        if pattern.hasPrefix("~/") {
            absolute = home.path + pattern.dropFirst()
        } else if pattern.hasPrefix("/") {
            absolute = pattern
        } else {
            absolute = home.appending(path: ".ssh").path + "/" + pattern
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(absolute, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }.sorted()
    }

    private static func collect(_ contents: String, includes: (String) -> [String], depth: Int, seen: inout Set<String>, hosts: inout [String]) {
        for line in contents.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let keyword = words.first?.lowercased() else { continue }
            switch keyword {
            case "host":
                for alias in words.dropFirst() where !alias.contains(where: { "*?!".contains($0) }) {
                    if seen.insert(alias).inserted { hosts.append(alias) }
                }
            case "include" where depth < maximumIncludeDepth:
                for pattern in words.dropFirst() {
                    for included in includes(pattern) {
                        collect(included, includes: includes, depth: depth + 1, seen: &seen, hosts: &hosts)
                    }
                }
            default:
                continue
            }
        }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
