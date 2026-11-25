import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkflowHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    let editor: WorkflowEditor
    let dismiss: () -> Void
    @State private var error: String?

    var body: some View {
        let versions = workspace.workflowHistory(editor.draft.id, in: project)
        VStack(alignment: .leading, spacing: 10) {
            Text("Version history").font(.system(size: 14, weight: .semibold))
            Text("Running tasks keep the version they started with.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            if versions.isEmpty {
                Text("No saved versions yet. Each save that changes behavior adds one.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(versions) { stats in
                HStack(alignment: .top, spacing: 10) {
                    Text("v\(stats.version.version)")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .frame(width: 34, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats.version.note.isEmpty ? "No note" : stats.version.note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(stats.version.note.isEmpty ? Theme.tertiaryText : Theme.primaryText)
                        Text(detail(stats))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    if stats.version.version == editor.draft.version {
                        Text("Current").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.successText)
                    } else {
                        Button("Restore") { restore(stats.version) }
                            .buttonStyle(PillButtonStyle(height: 24))
                            .disabled(editor.isDirty)
                            .help(editor.isDirty ? "Save or revert your changes first" : "Save this version again as v\(editor.draft.version + 1)")
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func detail(_ stats: WorkflowVersionStats) -> String {
        var parts = [stats.version.savedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(stats.runs) run\(stats.runs == 1 ? "" : "s")")
        if stats.activeRuns > 0 { parts.append("\(stats.activeRuns) in progress") }
        if let cost = stats.averageCostUSD { parts.append("avg \(cost.formatted(.currency(code: "USD")))") }
        return parts.joined(separator: " · ")
    }

    private func restore(_ version: WorkflowVersion) {
        guard let current = editor.saved else { return }
        do {
            let written = try workspace.restoreWorkflow(version, of: current, in: project)
            editor.markSaved(written)
            dismiss()
        } catch {
            self.error = "Couldn’t restore v\(version.version): \(error.localizedDescription)"
        }
    }
}
