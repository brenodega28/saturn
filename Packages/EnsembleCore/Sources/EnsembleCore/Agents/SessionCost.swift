import Foundation

extension Agent {
    mutating func startSessionTotals() {
        sessionCostUSD = 0
        sessionOutputTokens = 0
    }

    mutating func addTurnCost(of result: TurnResult, continuingProcess: Bool) -> Double {
        let continuesSessionTotals = continuingProcess || carriesSessionTotals(result)
        let cost = continuesSessionTotals ? max(0, result.totalCostUSD - sessionCostUSD) : result.totalCostUSD
        sessionCostUSD = result.totalCostUSD
        sessionOutputTokens = result.processOutputTokens ?? 0
        costUSD += cost
        return cost
    }

    private func carriesSessionTotals(_ result: TurnResult) -> Bool {
        guard let processOutputTokens = result.processOutputTokens else { return false }
        return result.totalCostUSD >= sessionCostUSD && processOutputTokens - result.usage.output >= sessionOutputTokens
    }
}
