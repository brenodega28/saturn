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
            ForEach(report.findings) { finding in
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

struct EvidenceCard: View {
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
                    Button("Open") { NSWorkspace.shared.open(item.url) }
                        .buttonStyle(.pill)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func thumbnail(_ item: Evidence) -> some View {
        if item.kind == .screenshot, let image = NSImage(contentsOf: item.url) {
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
