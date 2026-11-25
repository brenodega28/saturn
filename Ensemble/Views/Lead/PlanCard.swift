import EnsembleCore
import EnsembleUI
import SwiftUI

struct PlanCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
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
        let installed = SkillLibrary.skills(in: project.filesRoot, pluginSkills: workspace.pluginSkills(for: project)).map(\.name)
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
            if let spec = plan.spec {
                PlanSpecView(spec: spec)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                Text("No spec: the lead treated this as a one-sentence change.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            ForEach(Array(plan.tasks.enumerated()), id: \.element.id) { index, task in
                PlanTaskRow(
                    task: task, number: index + 1, isFirst: index == 0, isLast: index == plan.tasks.count - 1,
                    installedSkills: installed, plan: $plan
                )
                .overlay(alignment: .top) { Divider().overlay(Tokens.hair) }
            }
            if plan.tasks.isEmpty {
                Text("Every task was removed. Ask for a new plan.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(16)
            }
            footer
                .overlay(alignment: .top) { Divider().overlay(Tokens.hair) }
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
                workspace.rejectPlan(run, note: text)
                reload()
            }
            .padding(16)
        } else {
            HStack(spacing: 10) {
                Text("Each task gets its own builder and worktree")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Ask for a New Plan") { isAskingForNewPlan = true }
                    .buttonStyle(PillButtonStyle(height: 32))
                    .help("Send the plan back to the lead with a note")
                Button("Approve & Start Run") {
                    workspace.approvePlan(run, plan: plan)
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
    let installedSkills: [String]
    @Binding var plan: Plan

    var body: some View {
        let role = task.agent.builtInRole
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
                skillsMenu(role: role)
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

    private var skillsLabel: String {
        task.skills.isEmpty ? "No skills" : task.skills.joined(separator: ", ")
    }

    private func toggle(_ skill: String) {
        var skills = task.skills
        if let index = skills.firstIndex(of: skill) { skills.remove(at: index) } else { skills.append(skill) }
        plan.setSkills(skills, forTask: task.id)
    }

    private func skillsMenu(role: RoleDefinition) -> some View {
        let choices = (task.skills + installedSkills).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Menu {
            if choices.isEmpty {
                Text("No skills installed")
            }
            ForEach(choices, id: \.self) { skill in
                Toggle(skill, isOn: Binding(get: { task.skills.contains(skill) }, set: { _ in toggle(skill) }))
            }
        } label: {
            HStack(spacing: 6) {
                RoleBadge(role: role, size: 20)
                Text(role.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(skillsLabel).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(width: 260, height: 28)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tokens.hair2))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the skills this task’s \(role.name.lowercased()) loads")
        .accessibilityLabel("\(role.name), skills: \(skillsLabel)")
    }

}

struct PlanSpecView: View {
    let spec: PlanSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Acceptance criteria", spec.acceptanceCriteria)
            section("Interfaces", spec.interfaces)
            section("Out of scope", spec.outOfScope)
            if !spec.verification.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verification").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Text(spec.verification).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                ForEach(items, id: \.self) { item in
                    Text("• " + item).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
