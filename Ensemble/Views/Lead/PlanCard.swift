import EnsembleCore
import EnsembleUI
import SwiftUI

struct PlanCard: View {
    @Environment(AppModel.self) private var model
    let run: Run
    let project: Project
    let reload: () -> Void
    @State private var plan: Plan
    @State private var isAskingForNewPlan = false
    @State private var note = ""

    init(run: Run, project: Project, plan: Plan, reload: @escaping () -> Void) {
        self.run = run
        self.project = project
        self.reload = reload
        self._plan = State(initialValue: plan)
    }

    var body: some View {
        let roles = model.config(for: project).roles
        VStack(alignment: .leading, spacing: 0) {
            header
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            ForEach(Array(plan.tasks.enumerated()), id: \.element.id) { index, task in
                PlanTaskRow(
                    task: task, number: index + 1, isFirst: index == 0, isLast: index == plan.tasks.count - 1,
                    roles: roles, plan: $plan
                )
                .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.05)) }
            }
            if plan.tasks.isEmpty {
                Text("Every task was removed. Ask for a new plan.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(16)
            }
            footer
                .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.06)) }
        }
        .background(Theme.fill, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.warning.opacity(0.35)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(run.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            Text(plan.sizeDescription).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text("Waiting for you")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: 0xFFB340))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Theme.warning.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footer: some View {
        if isAskingForNewPlan {
            NoteField(prompt: "What should the lead change?", note: $note, sendTitle: "Ask for a New Plan", cancel: { isAskingForNewPlan = false }) {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                model.performRunAction("Couldn’t send the plan back") { try model.engine.rejectPlan(run, note: text) }
                reload()
            }
            .padding(16)
        } else {
            HStack(spacing: 10) {
                Text("Each coding agent gets its own worktree")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Ask for a New Plan") { isAskingForNewPlan = true }
                    .buttonStyle(PillButtonStyle(height: 32))
                    .help("Send the plan back to the lead with a note")
                Button("Approve & Start Run") {
                    model.performRunAction("Couldn’t approve the plan") { try model.engine.approvePlan(run, plan: plan) }
                    reload()
                }
                .buttonStyle(PillButtonStyle(.primary, height: 32))
                .disabled(plan.tasks.isEmpty)
                .help("Approve this plan as edited and start building")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct PlanTaskRow: View {
    let task: PlanTask
    let number: Int
    let isFirst: Bool
    let isLast: Bool
    let roles: [RoleDefinition]
    @Binding var plan: Plan

    var body: some View {
        let role = roles.first { $0.id == task.role }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if !task.details.isEmpty {
                        Text(task.details).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                arrow("chevron.up", label: "Move up", disabled: isFirst) { plan.moveTask(id: task.id, by: -1) }
                arrow("chevron.down", label: "Move down", disabled: isLast) { plan.moveTask(id: task.id, by: 1) }
                Spacer(minLength: 8)
                roleMenu(selected: role)
            stepper
            Button {
                plan.removeTask(id: task.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Remove this task from the plan")
            .accessibilityLabel("Delete task \(number)")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    private func arrow(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel("\(label), task \(number)")
    }

    private func roleMenu(selected: RoleDefinition?) -> some View {
        Menu {
            ForEach(roles) { role in
                Toggle(role.name, isOn: Binding(get: { role.id == task.role }, set: { if $0 { plan.setRole(role.id, forTask: task.id) } }))
            }
        } label: {
            HStack(spacing: 6) {
                RoleBadge(role: selected, size: 20)
                Text(selected?.name ?? task.role).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(width: 170, height: 28)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change the role for this task")
        .accessibilityLabel("Role: \(selected?.name ?? task.role)")
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            countButton("minus", label: "Fewer agents", disabled: task.count <= Plan.agentsPerTask.lowerBound) {
                plan.setCount(task.count - 1, forTask: task.id)
            }
            Text("×\(task.count)")
                .font(.system(size: 12.5, weight: .semibold))
                .frame(minWidth: 24)
            countButton("plus", label: "More agents", disabled: task.count >= Plan.agentsPerTask.upperBound) {
                plan.setCount(task.count + 1, forTask: task.id)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 28)
        .background(Color.white.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How many agents for task \(number)")
    }

    private func countButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel(label)
    }
}
