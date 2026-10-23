import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let runs = model.leadRuns(in: project)
        let selected = model.selectedLeadRun(in: project)
        HStack(alignment: .top, spacing: 18) {
            if !runs.isEmpty {
                LeadRunList(project: project, runs: runs, selectedID: selected?.id)
                    .frame(width: 236)
            }
            VStack(spacing: 14) {
                if let selected {
                    RunConversation(run: selected, project: project)
                        .id(selected.id)
                } else {
                    NewRequestIntro(project: project)
                }
                LeadComposer(project: project)
                    .frame(maxWidth: 820)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LeadRunList: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let runs: [Run]
    let selectedID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.startNewLeadRequest(in: project)
            } label: {
                Label("New request", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill)
            .help("Describe a new task for the lead")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(runs) { run in
                        row(run)
                    }
                }
            }
        }
    }

    private func row(_ run: Run) -> some View {
        let isSelected = run.id == selectedID
        let detail = run.isActive ? (model.currentStepTitle(of: run) ?? run.status.label) : run.status.label
        return Button {
            model.showRun(run)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(run.status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title.isEmpty ? "Run #\(run.id ?? 0)" : run.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text("\(detail) · \(run.costUSD.formatted(.currency(code: "USD")))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent.opacity(0.22) : Color.clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(run.title), \(run.status.label), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct NewRequestIntro: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let config = model.config(for: project)
        Group {
            if config.workflows.isEmpty {
                EmptyState("No workflows yet", message: "The lead starts a workflow from .ensemble/workflows/. Add the defaults to get Feature delivery and Small task.") {
                    Button("Add Default Roles and Workflows") { model.installDefaultConfig(in: project) }
                        .buttonStyle(.primaryPill)
                }
            } else if model.leadRoles(in: project).isEmpty {
                EmptyState("No lead role", message: "A lead is a role with can_spawn: true. Add one in Settings › Roles, or pick a workflow that needs no lead.")
            } else {
                EmptyState("Talk to the lead", message: "Describe a task below. The lead plans it, you approve the plan, and the workflow runs.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
