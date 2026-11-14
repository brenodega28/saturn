import EnsembleCore
import Foundation
import Observation

extension AppModel {
    static let globalMonthlyBudgetKey = "usage.globalMonthlyBudgetUSD"

    var globalMonthlyBudget: Double? {
        let value = UserDefaults.standard.double(forKey: Self.globalMonthlyBudgetKey)
        return value > 0 ? value : nil
    }

    func setGlobalMonthlyBudget(_ budget: Double?) {
        if let budget, budget > 0 {
            UserDefaults.standard.set(budget, forKey: Self.globalMonthlyBudgetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.globalMonthlyBudgetKey)
        }
        checkBudgets()
    }

    static let globalWeeklyBudgetKey = "usage.globalWeeklyBudgetUSD"

    var globalWeeklyBudget: Double? {
        let value = UserDefaults.standard.double(forKey: Self.globalWeeklyBudgetKey)
        return value > 0 ? value : nil
    }

    func setGlobalWeeklyBudget(_ budget: Double?) {
        if let budget, budget > 0 {
            UserDefaults.standard.set(budget, forKey: Self.globalWeeklyBudgetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.globalWeeklyBudgetKey)
        }
        checkBudgets()
    }

    static let usageResetPointKey = "usage.resetPoint"

    var usageResetPoint: Date? {
        let interval = UserDefaults.standard.double(forKey: Self.usageResetPointKey)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    func resetUsage(at date: Date = .now) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.usageResetPointKey)
    }

    func clearUsageReset() {
        UserDefaults.standard.removeObject(forKey: Self.usageResetPointKey)
    }

    func usageReport(period: UsagePeriod) -> UsageReport? {
        _ = agents.usageRevision
        return try? database.usageReport(period: period, totalsCountingSince: usageResetPoint)
    }

    var displayedUsageTotals: UsageTotals {
        _ = agents.usageRevision
        return (try? database.usageTotals(countingSince: usageResetPoint)) ?? UsageTotals()
    }

    var monthlySpend: Double {
        _ = agents.usageRevision
        return (try? database.monthlySpend()) ?? 0
    }

    func budgetStatus(for project: Project) -> BudgetStatus {
        _ = agents.usageRevision
        guard let id = project.id else { return BudgetStatus(budgetUSD: nil, spentUSD: 0) }
        return (try? database.projectBudgetStatus(projectId: id)) ?? BudgetStatus(budgetUSD: project.settings.monthlyBudgetUSD, spentUSD: 0)
    }

    func weeklyBudgetStatus(for project: Project) -> BudgetStatus {
        _ = agents.usageRevision
        guard let id = project.id else { return BudgetStatus(budgetUSD: nil, spentUSD: 0) }
        return (try? database.projectWeeklyBudgetStatus(projectId: id)) ?? BudgetStatus(budgetUSD: project.settings.weeklyBudgetUSD, spentUSD: 0)
    }

    func setWeeklyBudget(_ budget: Double?, for project: Project) {
        var settings = project.settings
        settings.weeklyBudgetUSD = budget.flatMap { $0 > 0 ? $0 : nil }
        updateSettings(settings, for: project)
        checkBudgets()
    }

    func allowOverBudgetThisWeek(_ project: Project) {
        var settings = project.settings
        settings.budgetOverrideWeek = BudgetWeek.key(for: .now)
        updateSettings(settings, for: project)
    }

    func setMonthlyBudget(_ budget: Double?, for project: Project) {
        var settings = project.settings
        settings.monthlyBudgetUSD = budget.flatMap { $0 > 0 ? $0 : nil }
        updateSettings(settings, for: project)
        checkBudgets()
    }

    func allowOverBudgetThisMonth(_ project: Project) {
        var settings = project.settings
        settings.budgetOverrideMonth = BudgetMonth.key(for: .now)
        updateSettings(settings, for: project)
    }

    func ensureWithinBudget(_ project: Project) throws {
        guard let id = project.id else { return }
        try database.checkProjectBudget(projectId: id)
    }

    func startStallWatch(interval: Duration = .seconds(60)) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                reportStalledWorkers()
            }
        }
    }

    func reportStalledWorkers(now: Date = .now) {
        var stalled: [StalledWorker] = []
        for project in openProjects {
            for session in agentSessions(in: project) where session.agent.kind != .lead {
                guard let last = session.lastOutputAt, session.isRunning else { continue }
                let step = session.agent.runId.flatMap { liveRun(id: $0) }.flatMap { run in runWorkflow(run)?.step(run.currentStep ?? "") }
                stalled.append(StalledWorker(agent: session.agent, lastOutputAt: last, stallMinutes: WorkerState.stallMinutes(for: step)))
            }
        }
        do {
            try stallReporter.report(stalled, now: now)
        } catch {
            alert = AppAlert(title: "Couldn’t report a stuck worker", message: error.localizedDescription)
        }
    }

    func startBudgetMonitor() {
        checkBudgets()
        withObservationTracking {
            _ = agents.usageRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.startBudgetMonitor() }
        }
    }

    func checkBudgets() {
        do {
            try database.recordBudgetNotices(globalBudgetUSD: globalMonthlyBudget, globalWeeklyBudgetUSD: globalWeeklyBudget)
        } catch {
            alert = AppAlert(title: "Couldn’t check budgets", message: error.localizedDescription)
        }
    }
}
