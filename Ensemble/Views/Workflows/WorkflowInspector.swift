import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkflowInspector: View {
    @Bindable var editor: WorkflowEditor
    let roles: [RoleDefinition]
    let checks: [CheckDefinition]
    let issues: [ConfigIssue]
    let activeRuns: [Run]
    let suggestedLabels: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let report = editor.report {
                    TestRunReportCard(report: report, workflow: editor.draft) { editor.report = nil }
                }
                if let errorMessage = editor.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !activeRuns.isEmpty {
                    InFlightBanner(runs: activeRuns, isDirty: editor.isDirty)
                }
                IssueList(issues: issues, showsFile: false)
                selectionCard
                    .padding(18)
                    .card(cornerRadius: 20)
                tip
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var selectionCard: some View {
        switch editor.selection {
        case .workflow:
            WorkflowSettingsSection(editor: editor)
        case .trigger:
            TriggerSection(trigger: $editor.draft.trigger, suggestedLabels: suggestedLabels)
        case .end:
            EndSection(end: $editor.draft.end)
        case .step(let id):
            if let index = editor.draft.index(of: id) {
                StepSection(editor: editor, step: $editor.draft.steps[index], roles: roles, checks: checks)
                    .id(id)
            } else {
                WorkflowSettingsSection(editor: editor)
            }
        }
    }

    private var tip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tip").font(.system(size: 12, weight: .semibold))
            Text("Drag an agent onto an agent step to change who does it. Drag from the dot under a step to another step to connect them. A dashed line loops work back and stops after its loop limit.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.hover, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.hair))
    }
}

struct InspectorHeader: View {
    let kind: String
    let title: String
    let symbol: String
    let fill: AnyShapeStyle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(fill, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(Theme.secondaryText)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(2)
            }
        }
    }
}

struct InspectorField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkflowLabel(title)
            content
        }
    }
}

struct InspectorTextEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 96)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.hair2))
            .accessibilityLabel(title)
    }
}

extension Binding where Value == String? {
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

extension Binding where Value == [String]? {
    var orEmpty: Binding<[String]> {
        Binding<[String]>(get: { wrappedValue ?? [] }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

private struct WorkflowSettingsSection: View {
    @Bindable var editor: WorkflowEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(kind: "Workflow", title: editor.draft.name.isEmpty ? "Untitled workflow" : editor.draft.name, symbol: "point.3.connected.trianglepath.dotted", fill: AnyShapeStyle(Theme.accent.gradient))
            InspectorField("Name") {
                TextField("Name", text: $editor.draft.name).textFieldStyle(.roundedBorder).labelsHidden()
            }
            InspectorField("Description") {
                TextField("What this workflow is for", text: $editor.draft.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(2...4)
            }
            InspectorField("Version") {
                Text(versionText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InspectorField("File") {
                Text(editor.isNew ? "Saved as .ensemble/workflows/<name>.yaml" : ".ensemble/workflows/\(editor.draft.id).yaml")
                    .font(Theme.monospaced)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private var versionText: String {
        if editor.isNew { return "v\(editor.draft.version) · new, not saved yet" }
        if editor.willBumpVersion { return "v\(editor.saved?.version ?? editor.draft.version) · saving makes v\(editor.nextVersion)" }
        return "v\(editor.draft.version)\(editor.isDirty ? " · layout changes only, the version stays" : "")"
    }
}

private struct TriggerSection: View {
    @Binding var trigger: WorkflowTrigger
    let suggestedLabels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(kind: "Trigger", title: trigger.labels.isEmpty ? "Every new chat" : "Labelled chats", symbol: "bubble.left.fill", fill: AnyShapeStyle(Tokens.fill2))
            InspectorField("Only for tasks labelled") {
                TokenEditor(items: $trigger.labels, placeholder: "Add a label, e.g. hotfix", suggestions: suggestedLabels)
            }
            InspectorField("Receives") {
                Text("A request from a Lead chat. \(trigger.labels.isEmpty ? "Any label matches." : "At least one of these labels must match.")")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EndSection: View {
    @Binding var end: WorkflowEnd

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(kind: "End", title: end.action.title, symbol: end.action.symbol, fill: AnyShapeStyle(Tokens.fill2))
            InspectorField("When the run finishes") {
                Picker("When the run finishes", selection: $end.action) {
                    ForEach(EndAction.allCases, id: \.self) { action in
                        Label(action.title, systemImage: action.symbol).tag(action)
                    }
                }
                .labelsHidden()
                .help("What Ensemble does with the approved branches")
            }
            Toggle("Clean up worktrees", isOn: $end.cleanUpWorktrees)
                .help("Remove each agent’s worktree once the run is done")
            InspectorField("Receives") {
                Text("Every approved branch from the run.")
                    .font(.system(size: 12.5))
            }
        }
    }
}

private struct StepSection: View {
    @Bindable var editor: WorkflowEditor
    @Binding var step: WorkflowStep
    let roles: [RoleDefinition]
    let checks: [CheckDefinition]
    @State private var idText = ""
    @State private var idError: String?

    var body: some View {
        let role = step.agent?.builtInRole
        let style = NodeStyle.step(step, role: role)
        VStack(alignment: .leading, spacing: 16) {
            InspectorHeader(kind: style.kind, title: step.displayTitle, symbol: style.symbol, fill: style.fill)
            who(role: role)
            InspectorField("Title") {
                TextField(step.id, text: $step.title.orEmpty).textFieldStyle(.roundedBorder).labelsHidden()
            }
            InspectorField("Step id") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Step id", text: $idText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .labelsHidden()
                        .onSubmit(rename)
                        .help("Routes and conditions refer to this id. Press Return to rename.")
                    if let idError {
                        Text(idError).font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                    }
                }
            }
            if [.agent, .spawn, .approval].contains(step.type) {
                InspectorField(step.type == .approval ? "What to check" : "Instructions") {
                    InspectorTextEditor(title: "Instructions", text: $step.instructions)
                }
            }
            if [.approval, .notify].contains(step.type) {
                InspectorField(step.type == .notify ? "Message" : "Message in the chat") {
                    TextField("Message", text: $step.message.orEmpty, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .lineLimit(1...4)
                }
            }
            if step.type == .check {
                CheckStepEditor(step: $step, checks: checks)
            }
            if step.type == .approval {
                Toggle("Remind me daily", isOn: $step.remindDaily)
                    .help("Post a reminder in the chat each day this approval waits")
            }
            if step.type == .condition {
                ConditionEditor(condition: Binding(get: { step.condition ?? StepCondition() }, set: { step.condition = $0 }), workflow: editor.draft, stepID: step.id)
            }
            InspectorField("Receives") {
                Text(StepInputsDescription.describe(step, in: editor.draft))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HandOffEditor(editor: editor, stepID: step.id)
            rules
            actions
        }
        .onAppear { idText = step.id }
        .onChange(of: step.id) { _, newValue in idText = newValue }
    }

    private var modelChoices: [String] {
        let base = AgentModel.allCases.map(\.rawValue)
        guard let current = step.model, !base.contains(current) else { return base }
        return base + [current]
    }

    @ViewBuilder
    private func who(role: RoleDefinition?) -> some View {
        InspectorField("Who does it") {
            switch step.type {
            case .agent, .spawn:
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Who does it", selection: $step.agent) {
                        Text("Choose an agent").tag(AgentKind?.none)
                        ForEach(step.type == .spawn ? [AgentKind.builder] : AgentKind.allCases) { kind in
                            Text(kind.name).tag(AgentKind?.some(kind))
                        }
                    }
                    .labelsHidden()
                    .help("Lead plans and reviews, a builder writes code, a checker reviews or tests from a fresh context")
                    Text(step.type == .spawn ? "Each task in the plan gets its own builder and worktree." : (step.agent?.summary ?? "Pick who runs this step."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Model", selection: Binding(
                        get: { step.model ?? "" },
                        set: { step.model = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Default (\((step.agent ?? .builder).defaultModel.modelTitle))").tag("")
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model.modelTitle).tag(model)
                        }
                    }
                    .help("The model this step’s agents use")
                }
            case .approval:
                Text("You").font(.system(size: 13, weight: .medium))
            case .condition:
                Text("Ensemble checks the rule below").font(.system(size: 13, weight: .medium))
            case .notify:
                Text("Ensemble posts in the chat").font(.system(size: 13, weight: .medium))
            case .check:
                Text("Ensemble runs the project’s checks").font(.system(size: 13, weight: .medium))
            case .gates:
                Text("Ensemble scans every branch").font(.system(size: 13, weight: .medium))
            }
        }
    }

    @ViewBuilder
    private var rules: some View {
        if [.agent, .spawn, .check].contains(step.type) {
            InspectorField("Rules") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Timeout").font(.system(size: 12.5)).frame(width: 74, alignment: .leading)
                        TextField("Timeout", value: $step.timeoutMinutes, format: .number, prompt: Text("None"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 70)
                            .help("Stop the step and ask you after this many minutes")
                        Text("minutes").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    HStack(spacing: 10) {
                        Text("On failure").font(.system(size: 12.5)).frame(width: 74, alignment: .leading)
                        Picker("On failure", selection: $step.onFailure) {
                            ForEach(FailureAction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .help("What happens when the step fails")
                    }
                    if step.type == .spawn {
                        Stepper(value: Binding(get: { step.maxAgents ?? 4 }, set: { step.maxAgents = $0 }), in: 1...16) {
                            HStack(spacing: 10) {
                                Text("Max agents").font(.system(size: 12.5)).frame(width: 74, alignment: .leading)
                                Text("\(step.maxAgents ?? 4)").monospacedDigit()
                            }
                        }
                        .help("The most agents this step runs at once")
                        Toggle("Reuse pinned builders", isOn: $step.reusePinned)
                            .help("Give tasks to idle pinned agents first, so their memory carries over, before spawning new ones")
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            if editor.draft.steps.first?.id != step.id {
                Button("Start here") { editor.edit { $0.makeFirst(step.id) } }
                    .buttonStyle(.pill)
                    .help("Make this the first step after the trigger")
            }
            Spacer()
            Button("Delete Step", role: .destructive) { editor.deleteSelectedStep() }
                .buttonStyle(.pill)
                .help("Remove this step and the routes that point to it")
        }
    }

    private func rename() {
        guard idText != step.id else {
            idError = nil
            return
        }
        if editor.renameStep(step.id, to: idText) {
            idError = nil
        } else {
            idError = "Use a new, unique id (not “end”)."
            idText = step.id
        }
    }
}

private struct ConditionEditor: View {
    @Binding var condition: StepCondition
    let workflow: WorkflowDefinition
    let stepID: String

    var body: some View {
        InspectorField("Condition") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Every rule you set must match for “Yes”; otherwise the gate answers “No”.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                InspectorField("Task has any label") {
                    TokenEditor(items: $condition.labelsAny.orEmpty, placeholder: "e.g. hotfix", suggestions: [])
                }
                InspectorField("Diff touches any path") {
                    TokenEditor(items: $condition.pathsAny.orEmpty, placeholder: "e.g. src/payments/**", suggestions: [])
                }
                HStack(spacing: 10) {
                    Text("Diff lines over").font(.system(size: 12.5))
                    TextField("Lines", value: $condition.diffLinesOver, format: .number, prompt: Text("Any"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 80)
                        .help("Match when the run changed more lines than this")
                }
                HStack(spacing: 10) {
                    Text("Outcome of").font(.system(size: 12.5))
                    Picker("Outcome of", selection: $condition.outcomeOf) {
                        Text("No step").tag(String?.none)
                        ForEach(workflow.steps.filter { $0.id != stepID }) { step in
                            Text(step.displayTitle).tag(String?.some(step.id))
                        }
                    }
                    .labelsHidden()
                    .help("Match on what an earlier step answered")
                }
                if condition.outcomeOf != nil {
                    HStack(spacing: 10) {
                        Text("equals").font(.system(size: 12.5))
                        TextField("Any outcome", text: $condition.equals.orEmpty)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .help("Leave empty to match any outcome")
                    }
                }
            }
        }
    }
}

private struct HandOffEditor: View {
    @Bindable var editor: WorkflowEditor
    let stepID: String

    var body: some View {
        if let step = editor.draft.step(stepID) {
            InspectorField("Hands off") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.routes.keys.sorted(), id: \.self) { outcome in
                        if let route = step.routes[outcome] {
                            RouteRow(editor: editor, stepID: stepID, outcome: outcome, route: route)
                        }
                    }
                    otherwise(step)
                    let unused = WorkflowDefinition.suggestedOutcomes(for: step.type).filter { step.routes[$0] == nil }
                    Menu {
                        ForEach(unused, id: \.self) { outcome in
                            Button(outcome.replacingOccurrences(of: "_", with: " ").capitalized) {
                                editor.edit { workflow in
                                    workflow.setRoute(from: stepID, outcome: outcome, to: WorkflowDefinition.endStepID)
                                }
                            }
                        }
                    } label: {
                        Label("Add route", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.pill)
                    .fixedSize()
                    .disabled(unused.isEmpty)
                    .help("Send a specific outcome to another step")
                }
            }
        }
    }

    private func otherwise(_ step: WorkflowStep) -> some View {
        let implicit = editor.draft.implicitTarget(after: stepID)
        let implicitName = implicit == WorkflowDefinition.endStepID ? "End" : editor.draft.step(implicit)?.displayTitle ?? implicit
        return HStack(spacing: 8) {
            StatusDot(Theme.neutral, size: 8)
            Text(step.routes.isEmpty ? "Done" : "Otherwise").font(.system(size: 12.5, weight: .semibold))
            Text("→").foregroundStyle(Theme.secondaryText)
            Picker("Next step", selection: Binding(
                get: { editor.draft.step(stepID)?.next },
                set: { next in editor.edit { workflow in
                    if let index = workflow.index(of: stepID) { workflow.steps[index].next = next }
                } }
            )) {
                Text(step.routes.isEmpty ? "Next in order (\(implicitName))" : "Nothing (ask me)").tag(String?.none)
                ForEach(editor.draft.steps.filter { $0.id != stepID }) { other in
                    Text(other.displayTitle).tag(String?.some(other.id))
                }
                Text("End").tag(String?.some(WorkflowDefinition.endStepID))
            }
            .labelsHidden()
            .help("Where the work goes when no route matches")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct RouteRow: View {
    @Bindable var editor: WorkflowEditor
    let stepID: String
    let outcome: String
    let route: WorkflowRoute
    @State private var outcomeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(OutcomeColor.color(for: outcome), size: 8)
                TextField("Outcome", text: $outcomeText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(minWidth: 70)
                    .onSubmit(renameOutcome)
                    .help("The outcome name the agent reports. Press Return to rename.")
                Button {
                    editor.edit { $0.removeRoute(from: stepID, outcome: outcome) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Remove route \(outcome)")
                .help("Remove this route")
            }
            HStack(spacing: 8) {
                Text("→").foregroundStyle(Theme.secondaryText)
                Picker("Goes to", selection: Binding(
                    get: { route.to },
                    set: { target in editor.edit { $0.setRoute(from: stepID, outcome: outcome, to: target, maxLoops: route.maxLoops) } }
                )) {
                    ForEach(editor.draft.steps) { other in
                        Text(other.displayTitle).tag(other.id)
                    }
                    Text("End").tag(WorkflowDefinition.endStepID)
                    if route.to != WorkflowDefinition.endStepID && editor.draft.step(route.to) == nil {
                        Text("\(route.to) (missing)").tag(route.to)
                    }
                }
                .labelsHidden()
                .help("The step that gets the work for this outcome")
                TextField("Max loops", value: Binding(
                    get: { route.maxLoops },
                    set: { loops in editor.edit { workflow in
                        if let index = workflow.index(of: stepID) { workflow.steps[index].routes[outcome]?.maxLoops = loops }
                    } }
                ), format: .number, prompt: Text("∞"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 44)
                .help("Max loops: stop and ask you after this many times")
                Text("loops").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 10, style: .continuous))
        .onAppear { outcomeText = outcome }
        .onChange(of: outcome) { _, newValue in outcomeText = newValue }
    }

    private func renameOutcome() {
        let trimmed = outcomeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != outcome else { return }
        var renamed = false
        editor.edit { renamed = $0.renameRoute(from: stepID, outcome: outcome, to: trimmed) }
        if !renamed { outcomeText = outcome }
    }
}

enum StepInputsDescription {
    static func describe(_ step: WorkflowStep, in workflow: WorkflowDefinition) -> String {
        let index = workflow.index(of: step.id) ?? 0
        let earlier = workflow.steps.prefix(index)
        let plansEarlier = earlier.contains { $0.type == .agent } && workflow.steps.contains { $0.type == .spawn }
        let senders = workflow.edges
            .filter { $0.to == step.id && $0.isLoopBack }
            .compactMap { workflow.step($0.from)?.displayTitle }
        let feedback = senders.isEmpty ? nil : "feedback from \(Array(Set(senders)).sorted().joined(separator: ", ")) when work comes back"
        switch step.type {
        case .agent:
            let parts = ["the task (title, body, labels)", "these instructions", plansEarlier ? "the approved plan" : nil, "the latest verdict", feedback, "every earlier step’s output"]
            return "Receives " + Self.list(parts.compactMap(\.self)) + "."
        case .spawn:
            let limit = step.maxAgents.map { "up to \($0) at once" } ?? "one per task"
            return Self.list(["One task from the approved plan per agent (\(limit))", "these instructions", feedback].compactMap(\.self)) + "."
        case .condition:
            return "The task’s labels, the run’s diff (changed paths and line count) and the outcomes of earlier steps."
        case .approval:
            return "The run’s branches, pins and the latest verdict. Approve to continue or send it back with changes."
        case .notify:
            return "The run so far. Posts the message in the chat and continues."
        case .gates:
            return "Every branch built in this run. Secrets, new dependencies and oversized changes wait for your decision; duplication, complexity and missing evidence are shown as warnings in Changes. Limits come from \(ProjectConfig.directoryName)/\(ReviewPolicy.fileName)."
        case .check:
            let rounds = step.maxRounds.map { "\($0)" } ?? "the project’s"
            return "Every branch built in this run. Failing checks go back to the branch’s author with their output, up to \(rounds) rounds, then to you in the chat."
        }
    }

    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }
}

private struct InFlightBanner: View {
    let runs: [Run]
    let isDirty: Bool

    var body: some View {
        let versions = Array(Set(runs.compactMap(\.workflowVersion))).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { "v\($0)" }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(runs.count) run\(runs.count == 1 ? "" : "s") keep\(runs.count == 1 ? "s" : "") the version \(runs.count == 1 ? "it" : "they") started with (\(versions.joined(separator: ", ")))")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(isDirty ? "Your changes apply to new runs only." : "Edits you save here apply to new runs only.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

private struct TestRunReportCard: View {
    let report: DryRunReport
    let workflow: WorkflowDefinition
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: report.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.status == .succeeded ? Theme.success : Theme.warning)
                    .accessibilityHidden(true)
                Text(report.status == .succeeded ? "Test run reached the end" : "Test run stopped")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Clear", action: clear)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .help("Hide the test run and its path on the canvas")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(report.steps.enumerated()), id: \.element.id) { offset, step in
                    HStack(spacing: 8) {
                        Text("\(offset + 1)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 16, alignment: .trailing)
                        Text(name(of: step.stepId) + (step.iteration > 1 ? " · #\(step.iteration)" : ""))
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(step.outcome.map(OutcomeColor.label) ?? label(for: step.status))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(step.outcome.map(OutcomeColor.color) ?? Theme.warning)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !report.notes.isEmpty || report.error != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.notes, id: \.self) { note in
                        Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                    }
                    if let error = report.error, !report.notes.contains(error) {
                        Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
    }

    private func name(of stepID: String) -> String {
        stepID == WorkflowDefinition.endStepID ? "End · \(workflow.end.action.title)" : workflow.step(stepID)?.displayTitle ?? stepID
    }

    private func label(for status: RunStepStatus) -> String {
        switch status {
        case .running: "Running"
        case .waitingOnYou: "Waiting"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}
