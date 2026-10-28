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
                Text("used to suggest skills and checks").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
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
                Text("Nothing Ensemble recognises yet. Agents start with general knowledge; add stack-specific skills any time.")
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

struct OnboardingSkillsStep: View {
    @Binding var draft: OnboardingDraft

    var body: some View {
        OnboardingSection(title: "Built-in agents") {
            ForEach(AgentKind.allCases) { kind in
                let role = kind.builtInRole
                let profile = draft.setup.permissions.resolve(for: kind, readOnly: !kind.editsCode)
                HStack(spacing: 12) {
                    AgentAvatar(size: 32, appearance: RoleAppearance(role: role))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.name).font(.system(size: 13, weight: .semibold))
                        Text(role.description).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    OnboardingTag(profile.name, tint: Theme.secondaryText)
                    OnboardingTag(AgentModel(rawValue: role.model)?.title ?? role.model, tint: Theme.link)
                }
                .padding(.vertical, 4)
            }
        }
        if !draft.bundledSkills.isEmpty {
            Picker("Starting point", selection: Binding(
                get: { draft.setup.skills.isEmpty ? 1 : 0 },
                set: { $0 == 0 ? draft.useRecommendedSkills() : draft.startEmpty() }
            )) {
                Text("Recommended for this stack").tag(0)
                Text("No skills").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            OnboardingSection {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Skills to install").font(.system(size: 13, weight: .semibold))
                    Text("\(draft.setup.skills.count) on").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.link)
                    Spacer()
                    Text("Added to .claude/skills; the Lead picks them per task").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                }
                ForEach(draft.bundledSkills) { skill in
                    skillRow(skill)
                }
            }
        }
        OnboardingSection(title: "Already installed") {
            if draft.installedSkills.isEmpty {
                Text("No skills yet. Add them to .claude/skills, ~/.claude/skills or install a plugin in Settings › Skills.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(draft.installedSkills) { skill in
                        OnboardingTag("\(skill.name) · \(skill.source.title.lowercased())", tint: Theme.link)
                    }
                }
            }
        }
    }

    private func skillRow(_ skill: BundledSkill) -> some View {
        let isOn = draft.setup.skills.contains(skill.name)
        return HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Theme.link).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    if let reason = draft.scan.skillReasons[skill.name] { OnboardingTag("from \(reason)", tint: Theme.successText) }
                }
                Text(skill.description).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("Install \(skill.name)", isOn: Binding(get: { isOn }, set: { _ in draft.toggle(skill: skill.name) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
        .opacity(isOn ? 1 : 0.55)
    }
}

struct OnboardingWorkflowStep: View {
    @Binding var draft: OnboardingDraft

    var body: some View {
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
            OnboardingRow(title: "Approve plans before agents start", detail: "The Lead shows tasks, skills and cost first") {
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
            card("Agents & skills", step: .skills, avatars: AgentKind.allCases.map(\.builtInRole), lines: [
                ("Agents", AgentKind.allCases.map(\.name).joined(separator: ", ")),
                ("Install", plan.skills.joined(separator: ", ").nonEmpty ?? "No skills"),
                ("Installed", draft.installedSkills.map(\.name).joined(separator: ", ").nonEmpty ?? "None yet"),
            ])
            card("Workflow", step: .workflow, lines: [
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
        OnboardingSection {
            HStack(spacing: 12) {
                AgentAvatar(size: 36, appearance: RoleAppearance(role: draft.lead))
                VStack(alignment: .leading, spacing: 2) {
                    Text("The \(draft.lead.name) is ready in Chat").font(.system(size: 14, weight: .semibold))
                    Text(plan.approvePlans ? "Describe what you want built. You’ll approve the plan before anything runs." : "Describe what you want built. The Lead plans it and the agents start right away.")
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
