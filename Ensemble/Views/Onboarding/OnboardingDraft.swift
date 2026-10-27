import EnsembleCore
import Foundation

struct OnboardingDraft {
    var scan: ProjectScan
    var name: String
    var setup: ProjectSetupPlan
    var catalog: [RoleDefinition]
    var enabled: Set<String>
    var customIDs: Set<String> = []
    var skillChoices: [String]
    var createAgentsFile: Bool

    init(project: Project, scan: ProjectScan, pluginSkills: some Sequence<String>) {
        self.scan = scan
        self.name = project.name
        self.setup = ProjectSetupPlan.recommended(for: scan)
        let suggested = scan.suggestedRoleIDs
        let catalog = ProjectSetup.roleCatalog
        self.catalog = suggested.compactMap { id in catalog.first { $0.id == id } } + catalog.filter { !suggested.contains($0.id) }
        self.enabled = Set(suggested)
        let roleSkills = catalog.flatMap(\.skills)
        self.skillChoices = Array(Set(roleSkills).union(SkillLibrary.installedSkills(in: project.url)).union(pluginSkills)).sorted()
        self.createAgentsFile = !scan.docs.contains("AGENTS.md")
    }

    var enabledRoles: [RoleDefinition] {
        catalog.filter { enabled.contains($0.id) }
    }

    var leadRoles: [RoleDefinition] {
        catalog.filter(\.canSpawn)
    }

    var lead: RoleDefinition? {
        catalog.first { $0.id == setup.leadRole }
    }

    var plan: ProjectSetupPlan {
        var plan = setup
        plan.roles = enabledRoles
        if let leadRole = plan.leadRole, !enabled.contains(leadRole) {
            plan.leadRole = plan.roles.first(where: \.canSpawn)?.id
        }
        return plan
    }

    var workflow: WorkflowDefinition? {
        setup.workflows.first { $0.id == setup.defaultWorkflow }
    }

    mutating func toggle(_ role: RoleDefinition) {
        if enabled.contains(role.id) {
            enabled.remove(role.id)
        } else {
            enabled.insert(role.id)
        }
    }

    mutating func useRecommendedRoles() {
        enabled = Set(scan.suggestedRoleIDs).union(customIDs)
    }

    mutating func startEmpty() {
        enabled = []
    }

    mutating func cycleModel(of role: RoleDefinition) {
        guard let index = catalog.firstIndex(where: { $0.id == role.id }) else { return }
        let models = AgentModel.allCases
        let current = models.firstIndex { $0.rawValue == catalog[index].model } ?? 0
        catalog[index].model = models[(current + 1) % models.count].rawValue
    }

    mutating func pickLead(_ role: RoleDefinition) {
        setup.leadRole = role.id
        enabled.insert(role.id)
    }

    mutating func addCustomRole(name: String, editsCode: Bool, skill: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = Slug.make(trimmed)
        guard !id.isEmpty else { return }
        while catalog.contains(where: { $0.id == id }) { id += "-2" }
        let role = RoleDefinition(
            id: id, name: trimmed,
            description: editsCode ? "Claude Code · edits in its own worktree" : "Claude Code · read-only",
            icon: editsCode ? "terminal" : "reviewer", color: "neutral",
            skills: skill.map { [$0] } ?? [], editsCode: editsCode
        )
        catalog.append(role)
        customIDs.insert(id)
        enabled.insert(id)
    }

    func summary(of step: OnboardingStep) -> String {
        switch step {
        case .project: "Folder, branches, task sources"
        case .roles: "\(enabled.count) role\(enabled.count == 1 ? "" : "s")"
        case .workflow: [workflow?.name, lead?.name].compactMap(\.self).joined(separator: " · ")
        case .rails: (["Checks"] + [setup.weeklyBudgetUSD.map { "$\(Int($0))/wk" }, setup.monthlyBudgetUSD.map { "$\(Int($0))/mo" }].compactMap(\.self)).joined(separator: " · ")
        case .review: "Then open Chat"
        }
    }
}
