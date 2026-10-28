#if DEBUG
import Foundation

typealias DebugFields = [String: JSONValue]

extension JSONValue {
    init(_ value: Int) {
        self = .number(Double(value))
    }

    init(_ value: Int64) {
        self = .number(Double(value))
    }

    init(_ value: Double) {
        self = .number(value)
    }

    init(_ value: Bool) {
        self = .bool(value)
    }

    init(_ value: String) {
        self = .string(value)
    }

    init(_ values: [String]) {
        self = .array(values.map(JSONValue.string))
    }

    init(_ value: String?) {
        self = value.map(JSONValue.string) ?? .null
    }

    init(_ value: Int64?) {
        self = value.map { .number(Double($0)) } ?? .null
    }

    init(_ value: Double?) {
        self = value.map(JSONValue.number) ?? .null
    }

    init?<Value: Encodable>(encoding value: Value) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = decoded
    }
}

enum DebugText {
    static func preview(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func truncatingStrings(in value: JSONValue, over limit: Int) -> JSONValue {
        switch value {
        case .string(let text) where text.utf8.count > limit:
            return .object(["preview": .string(String(text.prefix(limit))), "originalLength": JSONValue(text.count)])
        case .array(let items):
            return .array(items.map { truncatingStrings(in: $0, over: limit) })
        case .object(let object):
            return .object(object.mapValues { truncatingStrings(in: $0, over: limit) })
        default:
            return value
        }
    }

    static func truncatedField(_ text: String, limit: Int, into fields: inout DebugFields, key: String) {
        guard text.utf8.count > limit else {
            fields[key] = .string(text)
            return
        }
        fields[key] = .string(String(text.prefix(limit)))
        fields["originalLength"] = JSONValue(text.count)
    }
}
#endif
