import Foundation

public struct ChatLink: Hashable, Sendable {
    public static let scheme = "saturn"
    public static let schemes = [scheme, LegacyMigration.Legacy.urlScheme]
    static let host = "chat"
    static let messageQueryName = "message"
    static let daemonQueryName = "daemon"

    public var requestID: Int64
    public var messageID: Int64?
    public var daemon: DaemonID?

    public init(requestID: Int64, messageID: Int64? = nil, daemon: DaemonID? = nil) {
        self.requestID = requestID
        self.messageID = messageID
        self.daemon = daemon
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(requestID)"
        var items: [URLQueryItem] = []
        if let daemon { items.append(URLQueryItem(name: Self.daemonQueryName, value: daemon.uuidString.lowercased())) }
        if let messageID { items.append(URLQueryItem(name: Self.messageQueryName, value: String(messageID))) }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), Self.schemes.contains(scheme),
              components.host?.lowercased() == Self.host else { return nil }
        let segments = components.path.split(separator: "/")
        guard segments.count == 1, let requestID = Self.positiveID(segments[0]) else { return nil }
        let items = components.queryItems ?? []
        let messageValues = items.filter { $0.name == Self.messageQueryName }.map(\.value)
        guard messageValues.count <= 1 else { return nil }
        var messageID: Int64?
        if let value = messageValues.first {
            guard let value, let id = Self.positiveID(Substring(value)) else { return nil }
            messageID = id
        }
        let daemonValues = items.filter { $0.name == Self.daemonQueryName }.compactMap(\.value)
        let daemon = daemonValues.count == 1 ? DaemonID(uuidString: daemonValues[0]) : nil
        self.init(requestID: requestID, messageID: messageID, daemon: daemon)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    private static func positiveID(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), let id = Int64(text), id > 0 else { return nil }
        return id
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
