import Testing
@testable import EnsembleCore

@Suite struct SlugTests {
    @Test(arguments: [
        ("Django Dev 1", "django-dev-1"),
        ("  Refund model & API!  ", "refund-model-api"),
        ("Café crème", "cafe-creme"),
        ("feature/new--thing", "feature-new-thing"),
        ("日本語", ""),
        ("---", ""),
    ])
    func makesSlugs(input: String, expected: String) {
        #expect(Slug.make(input) == expected)
    }

    @Test func capsLengthWithoutTrailingDash() {
        let slug = Slug.make(String(repeating: "a", count: 47) + " bcd")
        #expect(slug.count <= Slug.maximumLength)
        #expect(!slug.hasSuffix("-"))
    }
}
