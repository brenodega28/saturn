import EnsembleCore
import EnsembleUI
import SwiftUI

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    @AppStorage("usage.period", store: AppDefaults.store) private var period: UsagePeriod = .month
    @AppStorage(AppModel.usageResetPointKey, store: AppDefaults.store) private var usageResetPoint: Double = 0
    @State private var isConfirmingReset = false

    var body: some View {
        let report = model.usageReport(period: period)
        AppScreen(title: "Usage", subtitle: "What agents cost across every project") {
            resetButton
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let resetPoint = model.usageResetPoint {
                        resetNote(resetPoint)
                    }
                    totals(report?.totals ?? UsageTotals())
                    if model.providerMode == .claudeSignIn {
                        estimateNote
                    }
                    spendWarningNote
                    breakdownHeader
                    if let report, !report.byProject.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                            BreakdownCard(title: "By project", rows: report.byProject)
                            BreakdownCard(title: "By run", rows: report.byRun)
                            BreakdownCard(title: "By agent kind", rows: report.byRole.map(named))
                            BreakdownCard(title: "By model", rows: report.byModel)
                        }
                        ExpensiveTurnsCard(turns: report.expensiveTurns, roleName: roleName)
                    } else {
                        EmptyState("No spend \(period == .allTime ? "yet" : period.title.lowercased())", message: "Spend by project, run, agent kind and model shows up here once agents start running.")
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
            StatTile(title: "This month", value: totals.monthUSD)
            StatTile(title: "All time", value: totals.allTimeUSD)
        }
    }

    private var resetButton: some View {
        Button {
            isConfirmingReset = true
        } label: { Label("Reset Usage", systemImage: "arrow.counterclockwise") }
            .buttonStyle(PillButtonStyle(height: 28))
            .font(.system(size: 12))
            .help("Restart the This week and This month totals from now")
            .confirmationDialog("Reset this week and this month?", isPresented: $isConfirmingReset) {
                Button("Reset Usage") {
                    model.resetUsage()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The This week and This month totals start counting from now. Usage history, all-time spend and breakdowns are unaffected, and you can undo this.")
            }
    }

    private func resetNote(_ resetPoint: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.counterclockwise").foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
            Text("This week and this month are counting since \(Text(resetPoint, format: .relative(presentation: .named))).")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Undo Reset") {
                model.clearUsageReset()
            }
            .buttonStyle(PillButtonStyle(height: 26))
            .font(.system(size: 12))
            .help("Count this week and this month from their usual start again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 12, style: .continuous))
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

    private var spendWarningNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "bell").foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
            Text("There are no spending limits. A chat gets a notice when it passes \(ChatSpendWarning.milestoneList); nothing is ever paused.")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 12, style: .continuous))
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
        for project in workspace.openProjects {
            if let role = workspace.config(for: project).role(id) { return role.name }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            Text(value.formatted(.currency(code: "USD")))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
