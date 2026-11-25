import SaturnCore
import Foundation
import Observation

extension AppModel {
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

    func migrateSettingsToDaemon() async {
        let migratedKey = "daemon.settingsMigrated.\(id.uuidString.lowercased())"
        guard !AppDefaults.store.bool(forKey: migratedKey),
              let settings = try? await send(SettingsCommands.Get()) else { return }
        if settings.providerMode == nil, let mode = app.providerMode {
            _ = try? await send(SettingsCommands.SetProviderMode(mode: mode))
        }
        AppDefaults.store.set(true, forKey: migratedKey)
    }
}
