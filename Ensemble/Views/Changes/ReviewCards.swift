import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct TierBadge: View {
    let tier: RiskTier

    var body: some View {
        switch tier {
        case .core:
            Label("Core · read line by line", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Theme.danger.opacity(0.14), in: Capsule())
                .help("A core or security path: read every line before approving")
        case .low:
            Text("Low risk")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Theme.fillRaised, in: Capsule())
                .help("A low-risk path such as docs; a quick look is enough")
        case .standard:
            EmptyView()
        }
    }
}

struct GatesCard: View {
    let report: GateReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.summary, systemImage: report.passed ? "checkmark.shield" : "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(report.passed ? Theme.warning : Theme.danger)
            if !report.criteria.isEmpty {
                CriteriaList(results: report.criteria)
            }
            ForEach(report.findings.filter { $0.kind != .criteria || report.criteria.isEmpty }) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title + (finding.agentName.map { " · \($0)" } ?? "") + (finding.file.map { " · \($0)\(finding.line.map { ":\($0)" } ?? "")" } ?? ""))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(finding.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
    }
}

struct CriteriaList: View {
    let results: [CriterionResult]

    var body: some View {
        let passed = results.count { $0.status == .pass }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance criteria").font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(passed)/\(results.count) pass").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.symbol(result.status))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Self.color(result.status))
                        .frame(width: 16)
                        .padding(.top, 1)
                        .accessibilityLabel(Self.label(result.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(result.criterion)")
                            .font(.system(size: 12.5, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if !result.evidence.isEmpty {
                            Text(result.evidence)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 10, style: .continuous))
    }

    static func symbol(_ status: CriterionResult.Status) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        case .notVerified: "questionmark.circle"
        }
    }

    static func color(_ status: CriterionResult.Status) -> Color {
        switch status {
        case .pass: Theme.successText
        case .fail: Theme.danger
        case .notVerified: Theme.warning
        }
    }

    static func label(_ status: CriterionResult.Status) -> String {
        switch status {
        case .pass: "Pass"
        case .fail: "Fail"
        case .notVerified: "Not verified"
        }
    }
}

struct EvidenceCard: View {
    @Environment(AppModel.self) private var model
    let evidence: [Evidence]
    let context: ReviewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Evidence").font(.system(size: 13, weight: .semibold))
            ForEach(evidence) { item in
                HStack(alignment: .top, spacing: 12) {
                    thumbnail(item)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 12.5, weight: .semibold))
                        Text([item.kind.rawValue.capitalized, item.agentId.flatMap { context.agentsByID[$0]?.name }].compactMap(\.self).joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                        if !item.note.isEmpty {
                            Text(item.note).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(model.localURL(forEvidence: item)) }
                        .buttonStyle(.pill)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func thumbnail(_ item: Evidence) -> some View {
        if item.kind == .screenshot, let image = NSImage(contentsOf: model.localURL(forEvidence: item)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 80)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel(item.title)
        } else {
            Image(systemName: item.kind == .benchmark ? "speedometer" : item.kind == .recording ? "film" : "doc.text")
                .font(.system(size: 22))
                .frame(width: 120, height: 80)
                .background(Theme.fillRaised, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }
}
