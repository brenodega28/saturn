import EnsembleCore
import EnsembleUI
import SwiftUI

struct SidebarRunRows: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        ForEach(model.activeLeadRuns(in: project)) { run in
            let step = model.currentStepTitle(of: run) ?? run.status.label
            Button {
                model.openRunDetail(run)
            } label: {
                HStack(spacing: 8) {
                    StatusDot(run.status.color, size: 6)
                    Text(run.title.isEmpty ? "Run #\(run.id ?? 0)" : run.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(step)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.leading, 24)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Show Run Details") { model.openRunDetail(run) }
                Button("Open in Lead Chat") { model.openRunInLead(run) }
            }
            .help("\(run.title) — \(run.status.label), \(step)")
            .accessibilityLabel("Run \(run.title), \(run.status.label), step \(step)")
            .accessibilityHint("Shows the run’s details")
        }
    }
}
