import EnsembleCore
import EnsembleUI
import SwiftUI

struct RolesSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var selectedID: String?
    @State private var draft: RoleDefinition?
    @State private var isNew = false
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    var body: some View {
        let config = model.config(for: project)
        SettingsPage("Roles", subtitle: "Reusable agent templates in .ensemble/roles. Each role sets the model, prompt, skills and documents its agents load.") {
            if !model.hasConfig(project) {
                InstallDefaultsCard(project: project)
            }
            IssueList(issues: unreadableRoleIssues(config))
            HStack(alignment: .top, spacing: 16) {
                roleList(config)
                if let draft {
                    editor(binding(for: draft), config: config)
                } else {
                    Text("Choose a role to edit, or add a new one.")
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
        .onAppear { selectFirst(in: config) }
        .confirmationDialog("Delete \(draft?.name ?? "role")?", isPresented: $isConfirmingDelete) {
            Button("Delete Role", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes .ensemble/roles/\(draft?.id ?? "").yaml. Agents already spawned from it keep running.")
        }
    }

    private func binding(for current: RoleDefinition) -> Binding<RoleDefinition> {
        Binding(get: { draft ?? current }, set: { draft = $0 })
    }

    private func roleList(_ config: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(config.roles) { role in
                let isSelected = role.id == selectedID && !isNew
                let issueCount = issues(for: role.id, in: config).count
                Button {
                    select(role)
                } label: {
                    HStack(spacing: 10) {
                        AgentAvatar(size: 26, appearance: RoleAppearance(role: role))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(role.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(role.editsCode ? "Writes code" : role.canSpawn ? "Lead" : "Read-only")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 4)
                        if issueCount > 0 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                                .accessibilityLabel("\(issueCount) problems")
                        }
                    }
                    .padding(8)
                    .background(isSelected ? Theme.fillSelected : Color.clear, in: .rect(cornerRadius: 10, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Button {
                newRole()
            } label: {
                Label("New Role", systemImage: "plus")
            }
            .buttonStyle(.pill)
            .padding(.top, 8)
            .help("Create a role in .ensemble/roles")
        }
        .padding(8)
        .frame(width: 220, alignment: .topLeading)
        .card(cornerRadius: 16)
    }

    private func editor(_ role: Binding<RoleDefinition>, config: ProjectConfig) -> some View {
        let value = role.wrappedValue
        let liveIssues = draftIssues(value, config: config)
        let context = RoleContext.build(role: value, config: config, repository: project.url)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AgentAvatar(size: 40, appearance: RoleAppearance(role: value))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.name.isEmpty ? "Untitled role" : value.name).font(.system(size: 17, weight: .bold))
                        Text(isNew ? "New role · saved as .ensemble/roles/\(Slug.make(value.name)).yaml" : ".ensemble/roles/\(value.id).yaml")
                            .font(Theme.monospaced)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                IssueList(issues: liveIssues, showsFile: false)

                field("Name") { TextField("Name", text: role.name).textFieldStyle(.roundedBorder).labelsHidden() }
                field("Description") { TextField("Description", text: role.description).textFieldStyle(.roundedBorder).labelsHidden() }
                HStack(spacing: 16) {
                    field("Icon") {
                        Picker("Icon", selection: role.icon) {
                            ForEach(choices(RoleAppearance.iconChoices, including: value.icon), id: \.self) { icon in
                                Label(icon, systemImage: RoleAppearance.symbol(for: icon)).tag(icon)
                            }
                        }
                        .labelsHidden()
                    }
                    field("Color") {
                        Picker("Color", selection: role.color) {
                            ForEach(choices(RoleAppearance.colorChoices, including: value.color), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    field("Model") {
                        Picker("Model", selection: role.model) {
                            ForEach(choices(AgentModel.allCases.map(\.rawValue), including: value.model), id: \.self) { Text($0.modelTitle).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                HStack(spacing: 24) {
                    Toggle("Edits code", isOn: role.editsCode)
                        .help("Coding roles get their own worktree and branch; others are read-only")
                    Toggle("Can spawn agents", isOn: role.canSpawn)
                        .help("Leads plan work and hand it to other roles")
                    field("Budget per run") {
                        TextField("Budget", value: role.budgetPerRun, format: .currency(code: "USD"), prompt: Text("No limit"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 110)
                    }
                }
                field("Skills") {
                    TokenEditor(items: role.skills, placeholder: "Add a skill", suggestions: Array(SkillLibrary.installedSkills(in: project.url)).sorted(), missing: Set(SkillLibrary.missingSkills(for: value, in: project.url)))
                }
                field("Documents this role reads") {
                    TokenEditor(items: role.docs, placeholder: "Add a repo path, e.g. docs/API.md", suggestions: config.docs.docs.compactMap(\.path), missing: Set(context.warnings.compactMap { warning in
                        if case .missingDoc(let path) = warning { return path }
                        return nil
                    }))
                }
                field("Prompt") {
                    TextEditor(text: role.prompt)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 160)
                        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                        .accessibilityLabel("Prompt")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
                }

                HStack {
                    if !isNew {
                        Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                            .buttonStyle(.pill)
                    }
                    Spacer()
                    Button("Revert") { revert(config) }
                        .buttonStyle(.pill)
                        .disabled(!isNew && config.role(value.id) == value)
                    Button("Save") { save(value, config: config) }
                        .buttonStyle(.primaryPill)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(Slug.make(value.name).isEmpty || (!isNew && config.role(value.id) == value))
                }
            }
            .padding(16)
            .card(cornerRadius: 16)

            ContextPreview(context: context)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            content()
        }
    }

    private func choices(_ base: [String], including current: String) -> [String] {
        base.contains(current) ? base : base + [current]
    }

    private func issues(for roleID: String, in config: ProjectConfig) -> [ConfigIssue] {
        config.issues.filter { $0.file == "\(ProjectConfig.directoryName)/roles/\(roleID).yaml" }
    }

    private func unreadableRoleIssues(_ config: ProjectConfig) -> [ConfigIssue] {
        let known = Set(config.roles.map { "\(ProjectConfig.directoryName)/roles/\($0.id).yaml" })
        return config.issues.filter { $0.file.contains("/roles/") && !known.contains($0.file) }
    }

    private func draftIssues(_ role: RoleDefinition, config: ProjectConfig) -> [ConfigIssue] {
        let id = isNew ? Slug.make(role.name) : role.id
        var candidate = role
        candidate.id = id
        var issues = ConfigValidator.validate(ProjectConfig(roles: [candidate])).map { ConfigIssue(file: $0.file, message: $0.message) }
        if isNew, config.role(id) != nil {
            issues.append(ConfigIssue(file: "", message: "a role with the id “\(id)” already exists"))
        }
        if Slug.make(role.name).isEmpty {
            issues.append(ConfigIssue(file: "", message: "a role needs a name"))
        }
        let saved = isNew ? [] : self.issues(for: role.id, in: config).filter { saved in !issues.contains { $0.message == saved.message } }
        return issues + saved
    }

    private func selectFirst(in config: ProjectConfig) {
        guard draft == nil, let role = config.roles.first else { return }
        select(role)
    }

    private func select(_ role: RoleDefinition) {
        selectedID = role.id
        draft = role
        isNew = false
        errorMessage = nil
    }

    private func newRole() {
        selectedID = nil
        draft = RoleDefinition(id: "", name: "New Role", prompt: "")
        isNew = true
        errorMessage = nil
    }

    private func revert(_ config: ProjectConfig) {
        if isNew {
            draft = nil
            isNew = false
            selectFirst(in: config)
        } else if let id = selectedID, let role = config.role(id) {
            draft = role
        }
        errorMessage = nil
    }

    private func save(_ role: RoleDefinition, config: ProjectConfig) {
        var role = role
        if isNew {
            role.id = Slug.make(role.name)
            if config.role(role.id) != nil {
                errorMessage = "A role with the id “\(role.id)” already exists."
                return
            }
        }
        do {
            try ProjectConfigLoader.write(role, repository: project.url)
            model.reloadConfig(for: project)
            select(model.config(for: project).role(role.id) ?? role)
        } catch {
            errorMessage = "Couldn’t save the role: \(error.localizedDescription)"
        }
    }

    private func delete() {
        guard let id = selectedID else { return }
        do {
            try ProjectConfigLoader.deleteRole(id, repository: project.url)
            model.reloadConfig(for: project)
            draft = nil
            selectedID = nil
            selectFirst(in: model.config(for: project))
        } catch {
            errorMessage = "Couldn’t delete the role: \(error.localizedDescription)"
        }
    }
}

struct ContextPreview: View {
    let context: RoleContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What an agent loads").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("≈ \(context.totalTokens.formatted()) tokens")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
            if context.sections.isEmpty {
                Text("Nothing beyond Ensemble’s own instructions. Add a prompt, documents or skills.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(context.sections) { section in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(for: section.kind))
                        .frame(width: 18)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(section.title).font(.system(size: 13, weight: .semibold))
                            if let source = section.source {
                                Text(source).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
                            }
                            if section.isTruncated {
                                Chip(text: "truncated", foreground: Theme.warning, background: Theme.warning.opacity(0.12))
                            }
                            Spacer()
                            Text("\(section.tokens.formatted()) tokens")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Text(section.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(3)
                    }
                }
            }
            ForEach(context.warnings) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Warning")
                    Text(warning.message).font(.system(size: 12))
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func symbol(for kind: RoleContext.SectionKind) -> String {
        switch kind {
        case .prompt: "text.quote"
        case .fileDoc: "doc.text"
        case .promptDoc: "text.bubble"
        case .skills: "sparkles"
        }
    }
}

struct TokenEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let suggestions: [String]
    var missing: Set<String> = []
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        let isMissing = missing.contains(item)
                        HStack(spacing: 4) {
                            if isMissing {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).accessibilityLabel("Missing")
                            }
                            Text(item).font(.system(size: 12, design: .monospaced))
                            Button {
                                items.removeAll { $0 == item }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(item)")
                            .help("Remove \(item)")
                        }
                        .foregroundStyle(isMissing ? Color(hex: 0xFFC36B) : Theme.primaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(isMissing ? Theme.warning.opacity(0.1) : Color.black.opacity(0.25), in: .rect(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isMissing ? Theme.warning.opacity(0.4) : Color.white.opacity(0.1)))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                let available = suggestions.filter { !items.contains($0) }
                if !available.isEmpty {
                    Menu {
                        ForEach(available, id: \.self) { suggestion in
                            Button(suggestion) { items.append(suggestion) }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick from the project")
                    .accessibilityLabel("Pick from the project")
                }
                Button("Add", action: add)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func add() {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        entry = ""
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                let next = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: next)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
