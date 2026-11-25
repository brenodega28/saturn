import Testing
@testable import Saturn

struct ChatCostTests {
    @Test func formatsDollarsWithCents() {
        #expect(ChatCost.label(4.15) == "$4.15")
        #expect(ChatCost.label(0.006) == "$0.01")
        #expect(ChatCost.label(12) == "$12.00")
        #expect(ChatCost.label(1234.5) == "$1,234.50")
    }

    @Test func hidesSpendThatRoundsToZero() {
        #expect(ChatCost.label(0) == nil)
        #expect(ChatCost.label(0.004) == nil)
        #expect(ChatCost.label(-1) == nil)
    }
}
