import EnsembleCore
import Foundation

struct OnboardingDraft {
    var scan: ProjectScan
    var name: String
    var setup: ProjectSetupPlan
    var bundledSkills: [BundledSkill]
    var installedSkills: [InstalledSkill]
    var createAgentsFile: Bool

    init(project: Project, scan: ProjectScan, pluginSkills: some Sequence<String>) {
        self.scan = scan
        self.name = project.name
        self.setup = ProjectSetupPlan.recommended(for: scan)
        self.bundledSkills = ProjectSetup.skillCatalog
        self.installedSkills = SkillLibrary.skills(in: project.url, pluginSkills: Set(pluginSkills))
        self.createAgentsFile = !scan.docs.contains("AGENTS.md")
    }

    var plan: ProjectSetupPlan { setup }

    var lead: RoleDefinition { AgentKind.lead.builtInRole }

    var workflow: WorkflowDefinition? {
        setup.workflows.first { $0.id == setup.defaultWorkflow }
    }

    mutating func toggle(skill: String) {
        if let index = setup.skills.firstIndex(of: skill) {
            setup.skills.remove(at: index)
        } else {
            setup.skills.append(skill)
        }
    }

    mutating func useRecommendedSkills() {
        setup.skills = scan.suggestedSkills
    }

    mutating func startEmpty() {
        setup.skills = []
    }

    func summary(of step: OnboardingStep) -> String {
        switch step {
        case .project: "Folder, branches, task sources"
        case .skills: setup.skills.isEmpty ? "Lead, builders, checkers" : "\(setup.skills.count) skill\(setup.skills.count == 1 ? "" : "s") to install"
        case .workflow: workflow?.name ?? setup.defaultWorkflow
        case .rails: (["Checks"] + [setup.weeklyBudgetUSD.map { "$\(Int($0))/wk" }, setup.monthlyBudgetUSD.map { "$\(Int($0))/mo" }].compactMap(\.self)).joined(separator: " · ")
        case .review: "Then open Chat"
        }
    }
}
