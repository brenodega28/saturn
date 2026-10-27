import EnsembleCore
import EnsembleUI
import SwiftUI

struct BudgetField: View {
    let budget: Double?
    let label: String
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text("$").foregroundStyle(Theme.secondaryText).accessibilityHidden(true)
            TextField("No limit", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .focused($isFocused)
                .onSubmit(save)
                .accessibilityLabel(label)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.fillRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .help("\(label). Leave empty for no limit, then press Return.")
        .onAppear { text = Self.text(for: budget) }
        .onChange(of: budget) { _, newValue in
            if !isFocused { text = Self.text(for: newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
    }

    private func save() {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let value = Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
        guard value != budget else {
            text = Self.text(for: budget)
            return
        }
        commit(value)
        text = Self.text(for: value)
    }

    static func text(for budget: Double?) -> String {
        guard let budget else { return "" }
        return budget.formatted(.number.precision(.fractionLength(budget.rounded() == budget ? 0 : 2)).grouping(.never))
    }
}

enum BudgetPeriodKind: String, CaseIterable, Identifiable {
    case week
    case month

    var id: Self { self }

    var title: String {
        switch self {
        case .week: "Weekly"
        case .month: "Monthly"
        }
    }

    var noun: String {
        switch self {
        case .week: "weekly"
        case .month: "monthly"
        }
    }

    var current: String {
        switch self {
        case .week: "this week"
        case .month: "this month"
        }
    }
}

struct BudgetMeter: View {
    let spent: Double
    let budget: Double?
    var period: BudgetPeriodKind = .month

    var body: some View {
        let fraction = budget.map { $0 > 0 ? spent / $0 : 0 } ?? 0
        let level = BudgetLevel(fraction: budget == nil ? nil : fraction)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(spent.formatted(.currency(code: "USD")))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                if let budget {
                    Text("of \(budget.formatted(.currency(code: "USD")))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    if let label = level.label {
                        Label(label, systemImage: level.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(level.color)
                            .labelStyle(.titleAndIcon)
                    }
                } else {
                    Text("no \(period.noun) limit").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }
            if budget != nil {
                ProportionBar(fraction: min(fraction, 1), color: level.color, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct BudgetLevel {
    let fraction: Double?

    var color: Color {
        guard let fraction else { return Theme.accent }
        if fraction >= 1 { return Theme.danger }
        if fraction >= 0.8 { return Theme.warning }
        return Theme.accent
    }

    var label: String? {
        guard let fraction else { return nil }
        if fraction >= 1 { return "Reached" }
        if fraction >= 0.8 { return "\(Int((fraction * 100).rounded(.down)))%" }
        return nil
    }

    var symbol: String {
        guard let fraction, fraction >= 1 else { return "exclamationmark.triangle.fill" }
        return "xmark.octagon.fill"
    }
}

struct ProportionBar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.1))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let clamped = max(0, min(fraction, 1))
                    Capsule()
                        .fill(color)
                        .frame(width: clamped > 0 ? max(height, proxy.size.width * clamped) : 0)
                }
            }
            .clipShape(Capsule())
    }
}

struct ProjectBudgetCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Budgets").font(.system(size: 13.5, weight: .semibold))
                Text("Spend across every run and agent in \(project.name). You get an Inbox notice at 80% and 100% of either cap; at 100% new runs and agent turns are refused until you raise it or allow the rest of the period.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(BudgetPeriodKind.allCases) { period in
                Text(period.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                ProjectBudgetEditor(project: project, showsName: false, period: period)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }
}

struct ProjectBudgetEditor: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var showsName = true
    var period: BudgetPeriodKind = .month

    var body: some View {
        let status = period == .week ? model.weeklyBudgetStatus(for: project) : model.budgetStatus(for: project)
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    summary(status)
                    Spacer(minLength: 8)
                    controls(status)
                }
                VStack(alignment: .leading, spacing: 10) {
                    summary(status)
                    controls(status)
                }
            }
            if status.isReached {
                Text(status.allowedOverBudget
                     ? "Over budget, but you allowed new work for the rest of \(period == .week ? BudgetWeek.title(for: .now) : BudgetMonth.title(for: .now))."
                     : "New runs and agent turns in \(project.name) are refused until you raise the budget or allow \(period.current).")
                    .font(.system(size: 12))
                    .foregroundStyle(status.allowedOverBudget ? Theme.secondaryText : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(_ status: BudgetStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text(project.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            }
            BudgetMeter(spent: status.spentUSD, budget: status.budgetUSD, period: period)
        }
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private func controls(_ status: BudgetStatus) -> some View {
        HStack(spacing: 8) {
            if status.blocksNewWork {
                Button("Allow \(period.current)") {
                    if period == .week { model.allowOverBudgetThisWeek(project) } else { model.allowOverBudgetThisMonth(project) }
                }
                .buttonStyle(PillButtonStyle(.secondary, height: 30))
                .help("Let runs and agent turns in \(project.name) continue until the end of the \(period == .week ? "week" : "month")")
                .fixedSize()
            }
            BudgetField(
                budget: period == .week ? project.settings.weeklyBudgetUSD : project.settings.monthlyBudgetUSD,
                label: "\(period.title) budget for \(project.name)"
            ) { value in
                if period == .week { model.setWeeklyBudget(value, for: project) } else { model.setMonthlyBudget(value, for: project) }
            }
            .fixedSize()
        }
    }
}
