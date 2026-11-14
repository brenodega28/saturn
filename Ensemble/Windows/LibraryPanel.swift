import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct PromptSnippet: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var text: String

    static let builtIn = [
        PromptSnippet(title: "Test first", text: "Write a failing test that reproduces the problem before you change any code, then make it pass."),
        PromptSnippet(title: "Keep it small", text: "Keep the change as small as possible. Don’t refactor code you don’t need to touch."),
        PromptSnippet(title: "Explain the plan", text: "Before you start, list the files you’ll change and why, then wait for my go-ahead."),
    ]
}

enum LibraryTab: String, CaseIterable {
    case roles = "Agents"
    case skills = "Skills"
    case stepTypes = "Step types"
    case snippets = "Snippets"
}

struct LibraryEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let explanation: String
    let symbol: String
    let fill: AnyShapeStyle
    let payload: String
    var stepType: StepType?
    var roleID: String?
}

extension StepType {
    var libraryTitle: String {
        switch self {
        case .agent: "Agent step"
        case .spawn: "Split"
        case .condition: "Condition"
        case .approval: "Human approval"
        case .notify: "Notify"
        case .check: "Checks"
        case .gates: "Gates"
        }
    }

    var libraryDetail: String {
        switch self {
        case .agent: "Run the Lead, a builder or a checker"
        case .spawn: "One builder per task in the plan"
        case .condition: "Branch on an outcome or a fact"
        case .approval: "You own the change"
        case .notify: "Tell you something without stopping"
        case .check: "Rails · format, lint, typecheck, tests"
        case .gates: "Rails · secrets, deps, duplication, complexity"
        }
    }

    var libraryExplanation: String {
        switch self {
        case .agent: "Runs one agent on the task: the Lead plans or reviews, a builder writes code in its own worktree, a checker reviews or tests from a fresh context. Its outcome decides where the run goes next."
        case .spawn: "Starts one builder per task in the approved plan, each on its own branch with the skills the Lead chose, and waits for them all."
        case .condition: "Routes the run by an outcome, a label or a fact about the change, without running an agent."
        case .approval: "Stops the run until you approve or send it back. Nothing merges without this."
        case .notify: "Posts a note in the chat and keeps going."
        case .check: "Runs your commands in a fresh worktree. Failing output goes back to the author, then you in the chat after the last round."
        case .gates: "Looks for secrets, new dependencies, duplication and complexity. Findings can block or just warn."
        }
    }

    var librarySymbol: String {
        switch self {
        case .agent: "a.circle"
        case .spawn: "arrow.triangle.branch"
        case .condition: "questionmark.diamond"
        case .approval: "checkmark.seal"
        case .notify: "bell"
        case .check: "checkmark"
        case .gates: "square.grid.3x3"
        }
    }
}

struct LibraryPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("library.snippets") private var storedSnippets: Data?
    @State private var tab: LibraryTab = .stepTypes
    @State private var query = ""
    @State private var selection: String?
    @State private var note: String?
    let dismiss: () -> Void

    var body: some View {
        let entries = self.entries(for: tab).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
        let selected = entries.first { $0.id == selection } ?? entries.first
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(LibraryTab.allCases, id: \.self) { candidate in
                    Button { tab = candidate } label: {
                        HStack(spacing: 4) {
                            Text(candidate.rawValue)
                            Text("\(self.entries(for: candidate).count)").font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.system(size: 12, weight: tab == candidate ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(tab == candidate ? Tokens.fill2 : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == candidate ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Tokens.hover, in: .rect(cornerRadius: 9, style: .continuous))
            .padding(12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                TextField("Filter", text: $query).textFieldStyle(.plain)
                if tab == .snippets {
                    Button { addSnippet() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Save the clipboard as a snippet")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12)
            Divider().overlay(Theme.hairline).padding(.top, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(entries) { entry in
                        row(entry, isSelected: entry.id == selected?.id)
                    }
                    if entries.isEmpty {
                        Text(emptyMessage).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).padding(24)
                    }
                }
                .padding(6)
            }
            .frame(height: 300)
            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 6) {
                Text(selected?.title ?? "Library").font(.system(size: 13, weight: .semibold))
                Text(selected?.explanation ?? "Agents, skills, step types and prompt snippets.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note ?? hint).font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: 460)
        .background(Tokens.menu, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tokens.hair2))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
    }

    private var hint: String {
        switch tab {
        case .roles, .stepTypes: "Drag into a workflow, or double-click to add it to the open workflow."
        case .skills, .snippets: "Drag into a chat, or double-click to copy."
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .roles: "No agents match."
        case .skills: "No skills installed. Add them under .claude/skills or install a plugin."
        case .stepTypes: "No step types match."
        case .snippets: "No snippets. Copy some text and press + to save it."
        }
    }

    private func row(_ entry: LibraryEntry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(entry.fill, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12.5, weight: .semibold))
                Text(entry.detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.accent.opacity(0.24) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(count: 2) { use(entry) }
        .onTapGesture { selection = entry.id }
        .draggable(entry.payload)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Use") { use(entry) }
    }

    private var snippets: [PromptSnippet] {
        storedSnippets.flatMap { try? JSONDecoder().decode([PromptSnippet].self, from: $0) } ?? PromptSnippet.builtIn
    }

    private func addSnippet() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            note = "Copy some text first, then press +."
            return
        }
        let title = String(text.split(separator: "\n").first?.prefix(40) ?? "Snippet")
        storedSnippets = try? JSONEncoder().encode(snippets + [PromptSnippet(title: title, text: text)])
        note = "Saved “\(title)”."
    }

    private func use(_ entry: LibraryEntry) {
        if let project = model.currentProject, let id = project.id, entry.stepType != nil || entry.roleID != nil {
            guard let editor = model.workflowEditors[id] else {
                note = "Open a workflow first."
                return
            }
            let config = model.config(for: project)
            if let type = entry.stepType {
                editor.addStep(type, role: nil, at: nil)
            } else if let roleID = entry.roleID, let role = config.role(roleID) {
                editor.addStep(.agent, role: role, at: nil)
            }
            model.open(.workflows)
            note = "Added \(entry.title) to \(editor.draft.name)."
        } else {
            model.copyToPasteboard(entry.payload)
            note = "Copied. Paste it into a chat."
        }
    }

    private func entries(for tab: LibraryTab) -> [LibraryEntry] {
        switch tab {
        case .roles:
            let roles = model.currentProject.map { model.config(for: $0).roles } ?? []
            return roles.map { role in
                let appearance = RoleAppearance(role: role)
                return LibraryEntry(
                    id: "role-\(role.id)", title: role.name, detail: role.description,
                    explanation: role.description,
                    symbol: appearance.symbol, fill: AnyShapeStyle(appearance.palette.gradient),
                    payload: PaletteItem.role(role.id).payload, roleID: role.id
                )
            }
        case .skills:
            guard let project = model.currentProject else { return [] }
            return SkillLibrary.skills(in: project.filesRoot, pluginSkills: model.pluginSkills(for: project)).map { skill in
                LibraryEntry(
                    id: "skill-\(skill.name)", title: skill.name, detail: skill.description.isEmpty ? "From \(skill.source.location)" : skill.description,
                    explanation: "Ask the Lead to give the \(skill.name) skill to a builder or checker.",
                    symbol: "sparkle", fill: AnyShapeStyle(Theme.memory.gradient), payload: "Use the \(skill.name) skill."
                )
            }
        case .stepTypes:
            return StepType.allCases.map { type in
                LibraryEntry(
                    id: "step-\(type.rawValue)", title: type.libraryTitle, detail: type.libraryDetail, explanation: type.libraryExplanation,
                    symbol: type.librarySymbol, fill: AnyShapeStyle((type == .check || type == .gates ? Color(hex: 0x48484A) : Theme.accent).gradient),
                    payload: PaletteItem.type(type).payload, stepType: type
                )
            }
        case .snippets:
            return snippets.map { snippet in
                LibraryEntry(id: "snippet-\(snippet.id)", title: snippet.title, detail: snippet.text, explanation: snippet.text, symbol: "text.quote", fill: AnyShapeStyle(Theme.warning.gradient), payload: snippet.text)
            }
        }
    }
}
