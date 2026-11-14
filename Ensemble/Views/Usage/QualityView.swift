import EnsembleCore
import EnsembleUI
import SwiftUI

struct QualityView: View {
    @Environment(AppModel.self) private var model
    @State private var projectID: Int64?

    var body: some View {
        let ids = projectID.map { [$0] } ?? model.openProjects.compactMap(\.id)
        let report = (try? model.database.qualityReport(projectIds: ids)) ?? QualityReport(weeks: [])
        AppScreen(title: "Quality", subtitle: "Whether agent work is getting easier to trust, measured by outcomes, never by lines generated") {
            Picker("Project", selection: $projectID) {
                Text("All projects").tag(Int64?.none)
                ForEach(model.openProjects) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .labelsHidden()
            .fixedSize()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let total = report.total
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        QualityTile(title: "Median change size", value: total.medianChangeSize.map { "\($0) lines" }, detail: "Smaller changes are easier to review")
                        QualityTile(title: "Median time to approve", value: total.medianApprovalMinutes.map(Self.duration), detail: "From your approval step opening to your decision")
                        QualityTile(title: "Checks failing first time", value: total.checkFailureRate.map(Self.percent), detail: "\(total.checkRetries) extra round\(total.checkRetries == 1 ? "" : "s") over \(total.checkRuns) check steps")
                        QualityTile(title: "Rework rate", value: total.reworkRate.map(Self.percent), detail: "Finished runs you sent back at least once")
                        QualityTile(title: "Duplication · complexity", value: "\(total.duplicationWarnings) · \(total.complexityWarnings)", detail: "Gate warnings over 8 weeks")
                        QualityTile(title: "Cost per approved change", value: total.costPerApprovedChange.map { $0.formatted(.currency(code: "USD")) }, detail: "\(total.approvedChanges) approved changes")
                        QualityTile(title: "Rules learned", value: "\(total.rulesAdded)", detail: "Corrections encoded as rules, checks or protected paths")
                    }
                    weeksTable(report)
                    Text("Revert rate isn’t measured yet; rework counts changes you sent back before merging.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.trailing, 4)
                .padding(.bottom, 12)
            }
        }
    }

    private func weeksTable(_ report: QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(["Week", "Approved", "Median size", "To approve", "Checks failing", "Rework", "Dup · cx", "Per change"], header: true)
            ForEach(report.weeks.reversed()) { week in
                row([
                    week.start.formatted(.dateTime.month(.abbreviated).day()),
                    "\(week.approvedChanges)",
                    week.medianChangeSize.map { "\($0)" } ?? "–",
                    week.medianApprovalMinutes.map(Self.duration) ?? "–",
                    week.checkFailureRate.map(Self.percent) ?? "–",
                    week.reworkRate.map(Self.percent) ?? "–",
                    "\(week.duplicationWarnings) · \(week.complexityWarnings)",
                    week.costPerApprovedChange.map { $0.formatted(.currency(code: "USD")) } ?? "–",
                ], header: false)
            }
        }
        .padding(14)
        .card(cornerRadius: 16)
    }

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .font(.system(size: 12, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? Theme.secondaryText : Theme.primaryText)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { if header { Rectangle().fill(Tokens.hair).frame(height: 1) } }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func duration(_ minutes: Double) -> String {
        minutes < 120 ? "\(Int(minutes.rounded())) min" : (minutes / 60).formatted(.number.precision(.fractionLength(1))) + " h"
    }
}

private struct QualityTile: View {
    let title: String
    let value: String?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            Text(value ?? "–")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}
