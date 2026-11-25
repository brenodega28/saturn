import Foundation

extension Agent {
    mutating func startSessionTotals() {
        sessionCostUSD = 0
        sessionOutputTokens = 0
    }

    var hasSessionTotals: Bool {
        sessionCostUSD != 0 || sessionOutputTokens != 0
    }

    mutating func seedSessionTotals(fromTranscript lines: [String]) {
        guard let sessionId else { return }
        var currentSession: String?
        var lastResult: TurnResult?
        for line in lines {
            for event in ClaudeEvent.parse(line: line) {
                switch event {
                case .sessionStarted(let info):
                    currentSession = info.sessionID
                case .turnCompleted(let result) where currentSession == sessionId:
                    lastResult = result
                default:
                    break
                }
            }
        }
        guard let lastResult else { return }
        sessionCostUSD = lastResult.totalCostUSD
        sessionOutputTokens = lastResult.processOutputTokens ?? 0
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
