import EnsembleCore
import EnsembleUI
import SwiftUI

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("usage.period") private var period: UsagePeriod = .month
    @AppStorage(AppModel.globalMonthlyBudgetKey) private var globalBudget: Double = 0

    var body: some View {
        let report = model.usageReport(period: period)
        AppScreen(title: "Usage", subtitle: "What agents cost across every project") {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    totals(report?.totals ?? UsageTotals())
                    if model.providerMode == .claudeSignIn {
                        estimateNote
                    }
                    budgets
                    breakdownHeader
                    if let report, !report.byProject.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                            BreakdownCard(title: "By project", rows: report.byProject)
                            BreakdownCard(title: "By run", rows: report.byRun)
                            BreakdownCard(title: "By role", rows: report.byRole.map(named))
                            BreakdownCard(title: "By model", rows: report.byModel)
                        }
                        ExpensiveTurnsCard(turns: report.expensiveTurns, roleName: roleName)
                    } else {
                        EmptyState("No spend \(period == .allTime ? "yet" : period.title.lowercased())", message: "Spend by project, run, role and model shows up here once agents start running.")
                            .frame(minHeight: 260)
                    }
                }
                .padding(.trailing, 4)
                .padding(.bottom, 12)
            }
        }
    }

    private func totals(_ totals: UsageTotals) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: "This week", value: totals.weekUSD)
            StatTile(title: "This month", value: totals.monthUSD, budget: globalBudget > 0 ? globalBudget : nil)
            StatTile(title: "All time", value: totals.allTimeUSD)
        }
    }

    private var estimateNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Theme.info).accessibilityHidden(true)
            Text("Agents use your Claude sign-in, so these amounts are Claude Code’s estimates of what the tokens would cost. Your plan isn’t billed per token.")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.info.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var budgets: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Monthly budgets").font(.system(size: 15, weight: .semibold))
                Text("You get an Inbox notice at 80% and 100%. A project at 100% stops starting runs and agent turns until you raise its budget or allow the rest of the month.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    overallSummary
                    Spacer(minLength: 8)
                    overallField
                }
                VStack(alignment: .leading, spacing: 10) {
                    overallSummary
                    overallField
                }
            }
            ForEach(model.openProjects) { project in
                Divider().overlay(Color.white.opacity(0.06))
                ProjectBudgetEditor(project: project)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private var overallSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All projects").font(.system(size: 13.5, weight: .semibold))
            BudgetMeter(spent: model.monthlySpend, budget: globalBudget > 0 ? globalBudget : nil)
            Text("Only alerts; it never blocks work.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private var overallField: some View {
        BudgetField(budget: globalBudget > 0 ? globalBudget : nil, label: "Overall monthly budget") { value in
            model.setGlobalMonthlyBudget(value)
            globalBudget = value ?? 0
        }
        .fixedSize()
    }

    private var breakdownHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Where it went").font(.system(size: 15, weight: .semibold))
                Spacer()
                CapsuleTabs(UsagePeriod.allCases, selection: $period, title: \.title)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Where it went").font(.system(size: 15, weight: .semibold))
                CapsuleTabs(UsagePeriod.allCases, selection: $period, title: \.title)
            }
        }
    }

    private func roleName(_ id: String?) -> String? {
        guard let id else { return nil }
        for project in model.openProjects {
            if let role = model.config(for: project).role(id) { return role.name }
        }
        return id
    }

    private func named(_ row: UsageBreakdownRow) -> UsageBreakdownRow {
        guard row.key.hasPrefix("role-"), row.key != "role-none" else { return row }
        var renamed = row
        renamed.title = roleName(row.title) ?? row.title
        return renamed
    }
}

private struct StatTile: View {
    let title: String
    let value: Double
    var budget: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            Text(value.formatted(.currency(code: "USD")))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let budget {
                let fraction = value / budget
                ProportionBar(fraction: fraction, color: BudgetLevel(fraction: fraction).color)
                    .accessibilityHidden(true)
                Text("of \(budget.formatted(.currency(code: "USD"))) overall budget")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .card(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }
}

struct BreakdownCard: View {
    let title: String
    let rows: [UsageBreakdownRow]
    static let visibleRows = 8

    var body: some View {
        let shown = Self.folded(rows)
        let largest = shown.map(\.costUSD).max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Text(rows.reduce(0) { $0 + $1.costUSD }.formatted(.currency(code: "USD")))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(shown) { row in
                    BreakdownRow(row: row, fraction: largest > 0 ? row.costUSD / largest : 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(cornerRadius: 16)
    }

    static func folded(_ rows: [UsageBreakdownRow]) -> [UsageBreakdownRow] {
        guard rows.count > visibleRows else { return rows }
        let kept = Array(rows.prefix(visibleRows - 1))
        let rest = rows.dropFirst(visibleRows - 1)
        let other = UsageBreakdownRow(
            key: "other", title: "Other (\(rest.count))",
            costUSD: rest.reduce(0) { $0 + $1.costUSD }, tokens: rest.reduce(0) { $0 + $1.tokens }, turns: rest.reduce(0) { $0 + $1.turns }
        )
        return kept + [other]
    }
}

private struct BreakdownRow: View {
    let row: UsageBreakdownRow
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(row.costUSD.formatted(.currency(code: "USD")))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            }
            ProportionBar(fraction: fraction, color: Theme.accent, height: 6)
                .accessibilityHidden(true)
            Text([row.detail, "\(row.turns) turn\(row.turns == 1 ? "" : "s") · \(row.tokens.formatted(.number.notation(.compactName))) tokens"].compactMap(\.self).joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(.rect)
        .help("\(row.title): \(row.costUSD.formatted(.currency(code: "USD"))) over \(row.turns) turns, \(row.tokens.formatted()) tokens")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.costUSD.formatted(.currency(code: "USD"))), \(row.turns) turns")
    }
}

private struct ExpensiveTurnsCard: View {
    let turns: [ExpensiveTurn]
    let roleName: (String?) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most expensive turns").font(.system(size: 13.5, weight: .semibold))
            if turns.isEmpty {
                Text("No turns in this period.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(turns) { turn in
                HStack(alignment: .top, spacing: 12) {
                    Text(turn.costUSD.formatted(.currency(code: "USD")))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 64, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([turn.agentName ?? "Deleted agent", roleName(turn.role)].compactMap(\.self).joined(separator: " · "))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text([turn.projectName, turn.runTitle ?? "Outside runs", turn.model, "\(turn.tokens.formatted(.number.notation(.compactName))) tokens"].joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(turn.recordedAt, format: .relative(presentation: .named))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}
