import Foundation

public struct ChatLink: Hashable, Sendable {
    public static let scheme = "ensemble"
    static let host = "chat"
    static let messageQueryName = "message"

    public var requestID: Int64
    public var messageID: Int64?

    public init(requestID: Int64, messageID: Int64? = nil) {
        self.requestID = requestID
        self.messageID = messageID
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(requestID)"
        if let messageID {
            components.queryItems = [URLQueryItem(name: Self.messageQueryName, value: String(messageID))]
        }
        return components.url!
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host else { return nil }
        let segments = components.path.split(separator: "/")
        guard segments.count == 1, let requestID = Self.positiveID(segments[0]) else { return nil }
        let messageValues = (components.queryItems ?? []).filter { $0.name == Self.messageQueryName }.map(\.value)
        guard messageValues.count <= 1 else { return nil }
        if let value = messageValues.first {
            guard let value, let messageID = Self.positiveID(Substring(value)) else { return nil }
            self.init(requestID: requestID, messageID: messageID)
        } else {
            self.init(requestID: requestID)
        }
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
