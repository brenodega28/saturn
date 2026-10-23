import Foundation

extension KeyedEncodingContainer {
    mutating func encodeNumber(_ value: Double?, forKey key: Key) throws {
        guard let value else { return }
        if value.rounded() == value, abs(value) < Double(Int.max) {
            try encode(Int(value), forKey: key)
        } else {
            try encode(Decimal(string: String(value)) ?? Decimal(value), forKey: key)
        }
    }
}
