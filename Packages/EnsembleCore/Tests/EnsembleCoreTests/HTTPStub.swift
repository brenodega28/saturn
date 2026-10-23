import Foundation
import Synchronization

final class HTTPStub: Sendable {
    struct Request: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?

        var path: String { url.path(percentEncoded: true) }

        var query: [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func jsonBody() -> [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        func formBody() -> [String: String] {
            let text = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            var components = URLComponents()
            components.percentEncodedQuery = text
            return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }
    }

    struct Reply: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func json(_ text: String, headers: [String: String] = [:]) -> Reply {
            json(200, text, headers: headers)
        }

        static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current }, body: Data(text.utf8))
        }

        static func empty(_ status: Int = 204) -> Reply {
            Reply(status: status, headers: [:], body: Data())
        }
    }

    static let header = "X-Ensemble-Stub"
    private static let registry = Mutex<[String: HTTPStub]>([:])

    let id = UUID().uuidString
    let session: URLSession
    private let state = Mutex<(replies: [Reply], requests: [Request])>(([], []))

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        session = URLSession(configuration: configuration)
        Self.registry.withLock { $0[id] = self }
    }

    static func stub(for id: String) -> HTTPStub? {
        registry.withLock { $0[id] }
    }

    func enqueue(_ replies: Reply...) {
        state.withLock { $0.replies.append(contentsOf: replies) }
    }

    var requests: [Request] {
        state.withLock { $0.requests }
    }

    var pendingReplies: Int {
        state.withLock { $0.replies.count }
    }

    func respond(to request: Request) -> Reply {
        state.withLock { state in
            state.requests.append(request)
            guard !state.replies.isEmpty else {
                return Reply.json(599, #"{"message":"no stubbed reply"}"#)
            }
            return state.replies.removeFirst()
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: HTTPStub.header) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: HTTPStub.header),
              let stub = HTTPStub.stub(for: id),
              let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: HTTPStub.header)
        let recorded = HTTPStub.Request(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: headers,
            body: request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        )
        let reply = stub.respond(to: recorded)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
