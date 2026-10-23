import Testing
@testable import EnsembleCore

@Suite struct ModelCatalogTests {
    @Test func emptyQuerySuggestsAliasesThenFullNames() {
        #expect(ModelCatalog.suggestions(matching: "") == [
            "sonnet", "opus", "haiku", "fable",
            "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5",
        ])
    }

    @Test func queryMatchesNamesAndTitlesWithPrefixMatchesFirst() {
        #expect(ModelCatalog.suggestions(matching: "op") == ["opus", "claude-opus-5-5"])
        #expect(ModelCatalog.suggestions(matching: "Sonnet") == ["sonnet", "claude-sonnet-5-5"])
        #expect(ModelCatalog.suggestions(matching: "claude-h") == ["claude-haiku-5-5"])
        #expect(ModelCatalog.suggestions(matching: "gpt").isEmpty)
    }

    @Test func projectModelsAreSuggestedOnceAndOnlyWhenValid() {
        let suggestions = ModelCatalog.suggestions(matching: "claude", including: ["claude-opus-4-1", "opus", "gpt-4", "claude-opus-5-5"])
        #expect(suggestions == ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-4-1"])
    }

    @Test func validModelsAreAliasesOrFullClaudeNames() {
        #expect(ModelCatalog.isValid("fable"))
        #expect(ModelCatalog.isValid("claude-sonnet-5-5"))
        #expect(!ModelCatalog.isValid("claude-"))
        #expect(!ModelCatalog.isValid("claude-opus 5"))
        #expect(!ModelCatalog.isValid("Sonnet"))
        #expect(!ModelCatalog.isValid("gpt-5"))
    }
}
