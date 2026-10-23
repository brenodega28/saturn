import Foundation

struct HTTPRequest: Sendable, Equatable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var body: Data

    var path: String {
        target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
    }

    var keepsConnectionAlive: Bool {
        let connection = headers["connection"]?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
    }
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
    }

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: Data(value.compactJSON.utf8))
    }

    static func text(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers, body: Data(message.utf8))
    }

    var reason: String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }
}

enum HTTPParseError: Error, Equatable {
    case malformed(String)
    case headersTooLarge
    case bodyTooLarge

    var response: HTTPResponse {
        switch self {
        case .malformed(let reason): .text(400, reason)
        case .headersTooLarge: .text(431, "Request headers are too large.")
        case .bodyTooLarge: .text(413, "Request body is too large.")
        }
    }
}

struct HTTPRequestParser: Sendable {
    let maximumHeaderSize: Int
    let maximumBodySize: Int
    private(set) var buffer = Data()

    init(maximumHeaderSize: Int = 64 * 1024, maximumBodySize: Int = 16 * 1024 * 1024) {
        self.maximumHeaderSize = maximumHeaderSize
        self.maximumBodySize = maximumBodySize
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func nextRequest() throws(HTTPParseError) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.firstRange(of: separator) else {
            if buffer.count > maximumHeaderSize { throw .headersTooLarge }
            return nil
        }
        let headerLength = headerEnd.lowerBound - buffer.startIndex
        if headerLength > maximumHeaderSize { throw .headersTooLarge }

        var request = try Self.parseHead(Data(buffer[buffer.startIndex..<headerEnd.lowerBound]))
        let bodyStart = headerEnd.upperBound

        if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (body, end) = try decodeChunked(from: bodyStart) else { return nil }
            request.body = body
            buffer = Data(buffer[end...])
            return request
        }

        let length: Int
        if let declared = request.headers["content-length"] {
            guard let value = Int(declared.trimmingCharacters(in: .whitespaces)), value >= 0 else {
                throw .malformed("Invalid Content-Length.")
            }
            length = value
        } else {
            length = 0
        }
        if length > maximumBodySize { throw .bodyTooLarge }
        guard buffer.endIndex - bodyStart >= length else { return nil }
        request.body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        return request
    }

    private static func parseHead(_ head: Data) throws(HTTPParseError) -> HTTPRequest {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else {
            throw .malformed("Malformed request line.")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("Malformed header line.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), version: String(requestLine[2]), headers: headers, body: Data())
    }

    private func decodeChunked(from start: Data.Index) throws(HTTPParseError) -> (Data, Data.Index)? {
        let lineBreak = Data("\r\n".utf8)
        var body = Data()
        var cursor = start
        while true {
            guard let sizeEnd = buffer[cursor...].firstRange(of: lineBreak) else { return nil }
            let sizeLine = String(decoding: buffer[cursor..<sizeEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw .malformed("Invalid chunk size.") }
            cursor = sizeEnd.upperBound
            if size == 0 {
                while true {
                    guard let trailerEnd = buffer[cursor...].firstRange(of: lineBreak) else { return nil }
                    let isLast = trailerEnd.lowerBound == cursor
                    cursor = trailerEnd.upperBound
                    if isLast { return (body, cursor) }
                }
            }
            if body.count + size > maximumBodySize { throw .bodyTooLarge }
            guard buffer.endIndex - cursor >= size + 2 else { return nil }
            body.append(buffer[cursor..<(cursor + size)])
            cursor += size
            guard buffer[cursor..<(cursor + 2)] == lineBreak else { throw .malformed("Chunk is missing its terminator.") }
            cursor += 2
        }
    }
}
