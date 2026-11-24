import EnsembleCore
import Foundation
import Observation

extension AppModel {
    static let globalMonthlyBudgetKey = "usage.globalMonthlyBudgetUSD"

    var globalMonthlyBudget: Double? {
        let value = AppDefaults.store.double(forKey: Self.globalMonthlyBudgetKey)
        return value > 0 ? value : nil
    }

    func setGlobalMonthlyBudget(_ budget: Double?) {
        if let budget, budget > 0 {
            AppDefaults.store.set(budget, forKey: Self.globalMonthlyBudgetKey)
        } else {
            AppDefaults.store.removeObject(forKey: Self.globalMonthlyBudgetKey)
        }
        checkBudgets()
    }

    static let globalWeeklyBudgetKey = "usage.globalWeeklyBudgetUSD"

    var globalWeeklyBudget: Double? {
        let value = AppDefaults.store.double(forKey: Self.globalWeeklyBudgetKey)
        return value > 0 ? value : nil
    }

    func setGlobalWeeklyBudget(_ budget: Double?) {
        if let budget, budget > 0 {
            AppDefaults.store.set(budget, forKey: Self.globalWeeklyBudgetKey)
        } else {
            AppDefaults.store.removeObject(forKey: Self.globalWeeklyBudgetKey)
        }
        checkBudgets()
    }

    static let usageResetPointKey = "usage.resetPoint"

    var usageResetPoint: Date? {
        let interval = AppDefaults.store.double(forKey: Self.usageResetPointKey)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    func resetUsage(at date: Date = .now) {
        AppDefaults.store.set(date.timeIntervalSince1970, forKey: Self.usageResetPointKey)
    }

    func clearUsageReset() {
        AppDefaults.store.removeObject(forKey: Self.usageResetPointKey)
    }

    func checkBudgets() {
        for workspace in workspaces.values { workspace.checkBudgets() }
    }

    func usageReport(period: UsagePeriod) -> UsageReport? {
        local.usageReport(period: period)
    }

    var displayedUsageTotals: UsageTotals { local.displayedUsageTotals }

    var monthlySpend: Double { local.monthlySpend }

    var weeklySpend: Double { local.weeklySpend }
}

extension DaemonWorkspace {
    func usageReport(period: UsagePeriod) -> UsageReport? {
        _ = connection.usageRevision
        return try? database.usageReport(period: period, totalsCountingSince: app.usageResetPoint)
    }

    var displayedUsageTotals: UsageTotals {
        _ = connection.usageRevision
        return (try? database.usageTotals(countingSince: app.usageResetPoint)) ?? UsageTotals()
    }

    var monthlySpend: Double {
        _ = connection.usageRevision
        return (try? database.monthlySpend()) ?? 0
    }

    func budgetStatus(for project: Project) -> BudgetStatus {
        _ = connection.usageRevision
        guard let id = project.id else { return BudgetStatus(budgetUSD: nil, spentUSD: 0) }
        return (try? database.projectBudgetStatus(projectId: id)) ?? BudgetStatus(budgetUSD: project.settings.monthlyBudgetUSD, spentUSD: 0)
    }

    func weeklyBudgetStatus(for project: Project) -> BudgetStatus {
        _ = connection.usageRevision
        guard let id = project.id else { return BudgetStatus(budgetUSD: nil, spentUSD: 0) }
        return (try? database.projectWeeklyBudgetStatus(projectId: id)) ?? BudgetStatus(budgetUSD: project.settings.weeklyBudgetUSD, spentUSD: 0)
    }

    func setWeeklyBudget(_ budget: Double?, for project: Project) {
        var settings = project.settings
        settings.weeklyBudgetUSD = budget.flatMap { $0 > 0 ? $0 : nil }
        updateSettings(settings, for: project)
        app.checkBudgets()
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
        app.checkBudgets()
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

    func checkBudgets() {
        dispatch("Couldn’t check budgets", SettingsCommands.SetBudgets(monthlyUSD: app.globalMonthlyBudget, weeklyUSD: app.globalWeeklyBudget))
    }

    func migrateSettingsToDaemon() async {
        let migratedKey = "daemon.settingsMigrated.\(id.uuidString.lowercased())"
        guard !AppDefaults.store.bool(forKey: migratedKey),
              let settings = try? await send(SettingsCommands.Get()) else { return }
        if settings.providerMode == nil, let mode = app.providerMode {
            _ = try? await send(SettingsCommands.SetProviderMode(mode: mode))
        }
        if settings.globalMonthlyBudgetUSD == nil, settings.globalWeeklyBudgetUSD == nil, app.globalMonthlyBudget != nil || app.globalWeeklyBudget != nil {
            _ = try? await send(SettingsCommands.SetBudgets(monthlyUSD: app.globalMonthlyBudget, weeklyUSD: app.globalWeeklyBudget))
        }
        AppDefaults.store.set(true, forKey: migratedKey)
    }
}
