import EnsembleCore
import EnsembleUI
import SwiftUI

struct OnboardingProjectStep: View {
    @Binding var draft: OnboardingDraft
    let rescan: () async -> Void
    @State private var isScanning = false

    var body: some View {
        OnboardingSection {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Found in this folder").font(.system(size: 13, weight: .semibold))
                Text("used to suggest roles and skills").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button(isScanning ? "Scanning…" : "Scan again") {
                    Task {
                        isScanning = true
                        await rescan()
                        isScanning = false
                    }
                }
                .buttonStyle(PillButtonStyle(height: 26))
                .disabled(isScanning)
            }
            if draft.scan.found.isEmpty {
                Text("Nothing Ensemble recognises yet. You’ll get a general crew; add stack-specific roles any time.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(draft.scan.found) { item in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.success).frame(width: 7, height: 7).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 12.5, weight: .semibold))
                                Text(item.location).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Theme.fill, in: .rect(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
        OnboardingSection {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { basics }
                VStack(alignment: .leading, spacing: 12) { basics }
            }
        }
        OnboardingSection(title: "Where tasks come from") {
            OnboardingRow(title: "Chat", detail: "Describe a task; the lead plans it and starts a run") {
                Text("Always on").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(
                title: "GitHub Issues",
                detail: draft.scan.githubRepository.map { "\($0) · issues labelled agent-ready show up in Tasks" } ?? "No GitHub remote found. Connect one later in Settings › GitHub."
            ) {
                Toggle("GitHub Issues", isOn: $draft.setup.githubIssues)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(draft.scan.githubRepository == nil)
            }
        }
    }

    @ViewBuilder
    private var basics: some View {
        OnboardingField("Project name") {
            TextField("Project name", text: $draft.name).textFieldStyle(.roundedBorder).labelsHidden()
        }
        OnboardingField("Base branch") {
            TextField("Base branch", text: $draft.setup.baseBranch).textFieldStyle(.roundedBorder).labelsHidden()
        }
        OnboardingField("Agent branch prefix") {
            TextField("Agent branch prefix", text: $draft.setup.branchPrefix).textFieldStyle(.roundedBorder).labelsHidden()
        }
    }
}

struct OnboardingRolesStep: View {
    let project: Project
    @Binding var draft: OnboardingDraft
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newEditsCode = true
    @State private var newSkill: String?

    var body: some View {
        Picker("Starting point", selection: Binding(
            get: { draft.enabled.isEmpty ? 1 : 0 },
            set: { $0 == 0 ? draft.useRecommendedRoles() : draft.startEmpty() }
        )) {
            Text("Recommended for this stack").tag(0)
            Text("Start empty").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 380)
        OnboardingSection {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Roles").font(.system(size: 13, weight: .semibold))
                Text("\(draft.enabled.count) on").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.link)
                Spacer()
                Text("Agents are only created when a run needs them").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
            }
            ForEach(draft.catalog) { role in
                roleRow(role)
            }
            if isAdding {
                newRoleForm
            } else {
                Button {
                    isAdding = true
                } label: {
                    Label("Create a role", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(height: 30))
            }
        }
    }

    private func roleRow(_ role: RoleDefinition) -> some View {
        let isOn = draft.enabled.contains(role.id)
        let profile = draft.setup.permissions.resolve(for: role)
        return HStack(spacing: 12) {
            AgentAvatar(size: 32, appearance: RoleAppearance(role: role))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(role.name).font(.system(size: 13, weight: .semibold))
                    if draft.customIDs.contains(role.id) { OnboardingTag("Custom", tint: Theme.memory) }
                    if let reason = draft.scan.roleReasons[role.id] { OnboardingTag("from \(reason)", tint: Theme.successText) }
                }
                Text(role.description).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            OnboardingTag(role.skills.first ?? "no skill", tint: role.skills.isEmpty ? Theme.tertiaryText : Theme.link)
            OnboardingTag(profile.name, tint: Theme.secondaryText)
            Button(AgentModel(rawValue: role.model)?.title ?? role.model) { draft.cycleModel(of: role) }
                .buttonStyle(PillButtonStyle(height: 24))
                .help("Model: \(role.model). Click to change")
                .fixedSize()
            Toggle("Use \(role.name)", isOn: Binding(get: { isOn }, set: { _ in draft.toggle(role) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
        .opacity(isOn ? 1 : 0.55)
    }

    private var newRoleForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New role").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .bottom, spacing: 16) {
                OnboardingField("Name") {
                    TextField("Name", text: $newName, prompt: Text("e.g. Celery Developer")).textFieldStyle(.roundedBorder).labelsHidden()
                }
                OnboardingField("Can edit files") {
                    HStack(spacing: 8) {
                        Toggle("Can edit files", isOn: $newEditsCode).toggleStyle(.switch).labelsHidden()
                        Text(newEditsCode ? "Own worktree, Developer access" : "Read-only, Reviewer access")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            OnboardingField("Force a skill") {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        skillChip(nil)
                        ForEach(draft.skillChoices, id: \.self) { skillChip($0) }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack {
                Spacer()
                Button("Cancel") { isAdding = false }.buttonStyle(PillButtonStyle(height: 28))
                Button("Add role") {
                    draft.addCustomRole(name: newName, editsCode: newEditsCode, skill: newSkill)
                    newName = ""
                    newSkill = nil
                    newEditsCode = true
                    isAdding = false
                }
                .buttonStyle(PillButtonStyle(.primary, height: 28))
                .disabled(Slug.make(newName).isEmpty)
            }
        }
        .padding(14)
        .background(Theme.fill, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
    }

    private func skillChip(_ skill: String?) -> some View {
        let isOn = newSkill == skill
        return Button(skill ?? "no skill") { newSkill = skill }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? Theme.accent.opacity(0.2) : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(isOn ? Theme.accent.opacity(0.6) : Color.white.opacity(0.12)))
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct OnboardingWorkflowStep: View {
    @Binding var draft: OnboardingDraft

    var body: some View {
        OnboardingSection(title: "Who answers in Chat by default") {
            ForEach(draft.leadRoles) { role in
                OnboardingChoice(isOn: draft.setup.leadRole == role.id) { draft.pickLead(role) } content: {
                    AgentAvatar(size: 30, appearance: RoleAppearance(role: role))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.name).font(.system(size: 13, weight: .semibold))
                        Text(role.description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        OnboardingSection(title: "Default workflow") {
            ForEach(draft.setup.workflows) { workflow in
                OnboardingChoice(isOn: draft.setup.defaultWorkflow == workflow.id) { draft.setup.defaultWorkflow = workflow.id } content: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(workflow.name).font(.system(size: 13, weight: .semibold))
                        Text(workflow.description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                        Text(workflow.steps.map(\.displayTitle).joined(separator: "  →  "))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.link)
                    }
                }
            }
        }
        OnboardingSection {
            OnboardingRow(title: "When a run finishes", detail: "What Ensemble does with approved work") {
                Picker("When a run finishes", selection: $draft.setup.endAction) {
                    Text("Open a PR").tag(EndAction.pullRequest)
                    Text("Push branch").tag(EndAction.push)
                    Text("Keep local").tag(EndAction.leave)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(title: "Approve plans before agents start", detail: "The lead shows tasks, roles and cost first") {
                Toggle("Approve plans before agents start", isOn: $draft.setup.approvePlans).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

struct OnboardingRailsStep: View {
    @Binding var draft: OnboardingDraft

    var body: some View {
        OnboardingSection {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Checks Ensemble runs on every change").font(.system(size: 13, weight: .semibold))
                Text(draft.scan.checks.checks.isEmpty ? "none found" : "detected from the repo").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
            }
            if let checks = draft.setup.checks, !checks.checks.isEmpty {
                ForEach(checks.checks) { check in
                    HStack(spacing: 10) {
                        Text(check.name.capitalized).font(.system(size: 12.5, weight: .semibold)).frame(width: 90, alignment: .leading)
                        Text(check.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        OnboardingTag("Suggested", tint: Theme.link)
                    }
                }
            } else {
                Text("Ensemble couldn’t find a test, lint or format command. Add them later in Settings › Checks; until then nothing verifies agents’ work.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(title: "Retries before the Inbox", detail: "Failing output goes back to the agent. After the last round, the task waits for you.") {
                Stepper("\(retries) round\(retries == 1 ? "" : "s")", value: Binding(get: { retries }, set: { setRetries($0) }), in: 1...5)
                    .fixedSize()
                    .disabled(draft.setup.checks == nil)
            }
        }
        OnboardingSection(title: "Spending and concurrency") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                limit("Weekly budget", value: $draft.setup.weeklyBudgetUSD, step: 10, range: 10...500, hint: "Resets Monday. Agents pause and ask at the cap")
                limit("Monthly budget", value: $draft.setup.monthlyBudgetUSD, step: 20, range: 20...2000, hint: "Resets on the 1st. Whichever cap hits first wins")
                limit("Per run", value: $draft.setup.perRunBudgetUSD, step: 1, range: 1...50, hint: "A run stops for approval above this")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agents at once").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Stepper("\(draft.setup.maxConcurrentAgents)", value: $draft.setup.maxConcurrentAgents, in: 1...8)
                        .font(.system(size: 17, weight: .bold))
                    Text("Each coding agent uses its own worktree").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        OnboardingSection(title: "What agents may do without asking") {
            OnboardingRow(title: "Run tests and linters while working", detail: "Agents may run them early. Ensemble still runs the real checks itself") {
                Toggle("Run tests and linters while working", isOn: $draft.setup.testsWithoutAsking).toggleStyle(.switch).labelsHidden()
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(title: "Use the network", detail: "Off: agents ask in Inbox before fetching anything") {
                Toggle("Use the network", isOn: $draft.setup.networkWithoutAsking).toggleStyle(.switch).labelsHidden()
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(title: "Install packages", detail: "Off: agents ask before pip or npm install") {
                Toggle("Install packages", isOn: $draft.setup.installsWithoutAsking).toggleStyle(.switch).labelsHidden()
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(title: "Edit existing tests", detail: "Read-only to agents. Any test change is pinned for separate review.") {
                Text("Never").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
            Divider().overlay(Theme.hairline)
            OnboardingRow(title: "Push to \(draft.setup.baseBranch.isEmpty ? "the base branch" : draft.setup.baseBranch)", detail: "Agents only push to \(ProjectPreferences.cleanPrefix(draft.setup.branchPrefix))/ branches. Merging is yours.") {
                Text("Never").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
        }
        OnboardingSection(title: "Docs every agent reads") {
            FlowLayout(spacing: 8) {
                if draft.createAgentsFile {
                    docChip("AGENTS.md", note: "create", isOn: true) { draft.createAgentsFile.toggle() }
                }
                ForEach(draft.scan.docs, id: \.self) { path in
                    docChip(path, note: "found", isOn: draft.setup.docs.contains(path)) {
                        if let index = draft.setup.docs.firstIndex(of: path) { draft.setup.docs.remove(at: index) } else { draft.setup.docs.append(path) }
                    }
                }
            }
        }
    }

    private var retries: Int { draft.setup.checks?.maxRounds ?? ChecksConfig.defaultMaxRounds }

    private func setRetries(_ value: Int) {
        draft.setup.checks?.maxRounds = value
    }

    private func limit(_ title: String, value: Binding<Double?>, step: Double, range: ClosedRange<Double>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            Stepper(
                value.wrappedValue.map { "$\(Int($0))" } ?? "No limit",
                value: Binding(get: { value.wrappedValue ?? range.lowerBound }, set: { value.wrappedValue = $0 }),
                in: range, step: step
            )
            .font(.system(size: 17, weight: .bold))
            Text(hint).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func docChip(_ path: String, note: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Theme.accent : Theme.secondaryText)
                Text(path).font(.system(size: 12.5, weight: .medium))
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isOn ? Theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? Theme.accent.opacity(0.5) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct OnboardingReviewStep: View {
    let draft: OnboardingDraft
    let edit: (OnboardingStep) -> Void

    var body: some View {
        let plan = draft.plan
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
            card("Project", step: .project, lines: [
                ("Name", draft.name),
                ("Branches", "\(ProjectPreferences.cleanPrefix(plan.branchPrefix))/* from \(plan.baseBranch)"),
                ("Tasks from", plan.githubIssues ? "Chat, GitHub Issues" : "Chat"),
            ])
            card("\(plan.roles.count) roles", step: .roles, avatars: plan.roles, lines: [
                ("Builders", plan.roles.filter(\.editsCode).map(\.name).joined(separator: ", ").nonEmpty ?? "None yet"),
                ("Reviewers", plan.roles.filter { !$0.editsCode && !$0.canSpawn }.map(\.name).joined(separator: ", ").nonEmpty ?? "None"),
            ])
            card("Workflow", step: .workflow, lines: [
                ("Lead", draft.lead?.name ?? "None"),
                ("Default", draft.workflow?.name ?? plan.defaultWorkflow),
                ("Finish", plan.endAction.onboardingTitle),
                ("Plans", plan.approvePlans ? "You approve first" : "Start right away"),
            ])
            card("Rails", step: .rails, lines: [
                ("Checks", plan.checks.map { $0.checks.map(\.name).joined(separator: " · ") } ?? "None yet"),
                ("Budget", [plan.weeklyBudgetUSD.map { "$\(Int($0))/week" }, plan.monthlyBudgetUSD.map { "$\(Int($0))/month" }, plan.perRunBudgetUSD.map { "$\(Int($0))/run" }].compactMap(\.self).joined(separator: " · ")),
                ("Agents", "\(plan.maxConcurrentAgents) at once"),
                ("Ask first", [plan.networkWithoutAsking ? nil : "network", plan.installsWithoutAsking ? nil : "installs", plan.testsWithoutAsking ? nil : "shell"].compactMap(\.self).joined(separator: ", ").nonEmpty ?? "nothing"),
            ])
        }
        if draft.enabledRoles.isEmpty {
            Label("Turn on at least one role to finish.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.warning)
        }
        OnboardingSection {
            HStack(spacing: 12) {
                if let lead = draft.lead { AgentAvatar(size: 36, appearance: RoleAppearance(role: lead)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(draft.lead?.name ?? "Your crew") is ready in Chat").font(.system(size: 14, weight: .semibold))
                    Text(plan.approvePlans ? "Describe what you want built. You’ll approve the plan before anything runs." : "Describe what you want built. The lead plans it and the crew starts right away.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            FlowLayout(spacing: 8) {
                ForEach(["Add a health check endpoint", "Fix the flaky test in CI", "Write docs for the setup steps"], id: \.self) { text in
                    Text(text)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.fillRaised, in: .capsule)
                }
            }
        }
    }

    private func card(_ title: String, step: OnboardingStep, avatars: [RoleDefinition] = [], lines: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Edit") { edit(step) }.buttonStyle(.plain).foregroundStyle(Theme.link).font(.system(size: 12))
            }
            if !avatars.isEmpty {
                CrewStack(palettes: avatars.map(\.palette), size: 22, border: Color(hex: 0x232327))
            }
            ForEach(lines, id: \.0) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.0).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText).frame(width: 74, alignment: .leading)
                    Text(line.1).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.fill, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension EndAction {
    var onboardingTitle: String {
        switch self {
        case .pullRequest: "Open a PR"
        case .merge: "Merge"
        case .push: "Push branch"
        case .leave: "Keep local"
        }
    }
}

struct OnboardingSection<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct OnboardingRow<Accessory: View>: View {
    let title: String
    let detail: String
    let accessory: Accessory

    init(title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

struct OnboardingField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OnboardingChoice<Content: View>: View {
    let isOn: Bool
    let pick: () -> Void
    let content: Content

    init(isOn: Bool, pick: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isOn = isOn
        self.pick = pick
        self.content = content()
    }

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                content
                Spacer(minLength: 0)
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Theme.accent : Theme.secondaryText)
            }
            .padding(12)
            .background(isOn ? Theme.accent.opacity(0.16) : Theme.fill, in: .rect(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(isOn ? Theme.accent.opacity(0.6) : Theme.hairline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct OnboardingTag: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
            .fixedSize()
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
