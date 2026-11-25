import Foundation

public enum Slug {
    public static let maximumLength = 48

    public static func make(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        var slug = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(maximumLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
