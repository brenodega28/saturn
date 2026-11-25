import AppKit
import SaturnCore
import SaturnUI
import SwiftUI
import UniformTypeIdentifiers

enum ReaderChoice: Hashable, CaseIterable, Identifiable {
    case all
    case leads
    case coding
    case reviewers
    case roles

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All agents"
        case .leads: "Lead only"
        case .coding: "Builders"
        case .reviewers: "Checkers"
        case .roles: "Choose agents…"
        }
    }

    init(_ readers: DocReaders) {
        switch readers {
        case .all: self = .all
        case .leads: self = .leads
        case .coding: self = .coding
        case .reviewers: self = .reviewers
        case .roles: self = .roles
        }
    }
}

extension DocReaders {
    func summary(roles: [RoleDefinition]) -> [String] {
        switch self {
        case .all: ["All agents"]
        case .leads: ["Lead"]
        case .coding: ["Builders"]
        case .reviewers: ["Checkers"]
        case .roles(let ids): ids.map { id in roles.first { $0.id == id }?.name ?? AgentKind.guessing(roleID: id).name }
        }
    }
}

struct DocsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project

    @State private var mode = Mode.file
    @State private var readerChoice = ReaderChoice.all
    @State private var chosenRoles: Set<String> = []
    @State private var promptTitle = ""
    @State private var promptBody = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isAdding = false

    enum Mode: String, CaseIterable, Identifiable {
        case file
        case prompt

        var id: Self { self }
        var title: String { self == .file ? "From file" : "Write a prompt" }
    }

    var body: some View {
        let config = workspace.config(for: project)
        let docs = config.docs.docs
        SettingsPage("Docs", subtitle: "Files every agent reads before it starts. Link a file from the repo to keep it in sync, or write a prompt that lives in .saturn/docs.yaml.") {
            if let errorMessage {
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(Tokens.danger).textSelection(.enabled)
            }
            IssueList(issues: config.issues.filter { $0.file.hasSuffix("docs.yaml") })
            if !docs.isEmpty {
                SettingsRows {
                    ForEach(Array(docs.enumerated()), id: \.offset) { index, doc in
                        DocRow(doc: doc, roles: config.roles, tokens: tokens(for: doc), isMissing: isMissing(doc), update: { updated in
                            replace(at: index, with: updated, in: config)
                        }, remove: {
                            remove(at: index, in: config)
                        })
                    }
                }
                SettingsNote("\(docs.filter(\.enabled).count) of \(docs.count) in use", color: Tokens.text3)
            }
            if isAdding || docs.isEmpty {
                addCard(config: config)
            } else {
                Button("+ Add a doc") { isAdding = true }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text, .pdf, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { addFile(url, config: workspace.config(for: project)) }
            }
        }
    }

    private func addCard(config: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add a doc").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Picker("Source", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            switch mode {
            case .file:
                VStack(alignment: .leading, spacing: 10) {
                    SettingsNote("Files inside the repo stay linked: agents read the current version on every turn.")
                    Button("Choose File…") { isImporting = true }
                        .buttonStyle(SectionButtonStyle())
                        .help("Pick a file inside \(project.name)")
                    let suggestions = suggestedFiles(config: config)
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: 6) {
                            Text("Found in repo, not added yet:")
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text2)
                            ForEach(suggestions, id: \.self) { path in
                                Button("+ \(path)") { addPath(path, config: config) }
                                    .buttonStyle(SectionButtonStyle(kind: .dashed, height: 26))
                                    .help("Add \(path)")
                            }
                        }
                    }
                }
            case .prompt:
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: $promptTitle, prompt: Text("e.g. Payments rules"))
                        .sectionField(width: nil)
                    TextEditor(text: $promptBody)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110)
                        .background(Tokens.window, in: .rect(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.hair2))
                        .accessibilityLabel("Prompt")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Who reads it").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
                FlowLayout(spacing: 8) {
                    readerChips(config: config)
                }
            }

            HStack {
                Spacer()
                if !config.docs.docs.isEmpty {
                    Button("Done") { isAdding = false }
                        .buttonStyle(SectionButtonStyle())
                }
                if mode == .prompt {
                    Button("Add Prompt") { addPrompt(config: config) }
                        .buttonStyle(SectionButtonStyle(kind: .primary))
                        .disabled(promptTitle.trimmingCharacters(in: .whitespaces).isEmpty || promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .sectionCard()
    }

    @ViewBuilder
    private func readerChips(config: ProjectConfig) -> some View {
        ForEach(ReaderChoice.allCases) { choice in
            if choice == .roles {
                Menu {
                    ForEach(config.roles) { role in
                        Toggle(role.name, isOn: Binding(
                            get: { chosenRoles.contains(role.id) },
                            set: { isOn in
                                if isOn { chosenRoles.insert(role.id) } else { chosenRoles.remove(role.id) }
                                readerChoice = .roles
                            }
                        ))
                    }
                } label: {
                    Text(chosenRoles.isEmpty ? choice.title : "\(chosenRoles.count) agents")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(readerChoice == choice ? Tokens.selection : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(readerChoice == choice ? Tokens.accent.opacity(0.34) : Tokens.hair2))
            } else {
                Button(choice.title) { readerChoice = choice }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(readerChoice == choice ? Tokens.selection : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(readerChoice == choice ? Tokens.accent.opacity(0.34) : Tokens.hair2))
                    .accessibilityAddTraits(readerChoice == choice ? .isSelected : [])
            }
        }
    }

    private var readers: DocReaders {
        switch readerChoice {
        case .all: .all
        case .leads: .leads
        case .coding: .coding
        case .reviewers: .reviewers
        case .roles: chosenRoles.isEmpty ? .all : .roles(chosenRoles.sorted())
        }
    }

    private func suggestedFiles(config: ProjectConfig) -> [String] {
        let added = Set(config.docs.docs.compactMap(\.path))
        let fileManager = FileManager.default
        var candidates = ["AGENTS.md", "CLAUDE.md", "README.md", "CONTRIBUTING.md"]
        let docsFolder = project.filesRoot.appending(path: "docs")
        if let files = try? fileManager.contentsOfDirectory(atPath: docsFolder.path) {
            candidates += files.filter { $0.lowercased().hasSuffix(".md") }.sorted().map { "docs/\($0)" }
        }
        return candidates.filter { !added.contains($0) && fileManager.fileExists(atPath: project.filesRoot.appending(path: $0).path) }
    }

    private func tokens(for doc: DocEntry) -> Int {
        if let path = doc.path {
            guard let file = SkillLibrary.file(path, in: project.filesRoot),
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { return 0 }
            return min(size, RoleContext.defaultDocumentLimit) / 4
        }
        return TokenEstimate.of(doc.prompt ?? "")
    }

    private func isMissing(_ doc: DocEntry) -> Bool {
        doc.path.map { SkillLibrary.file($0, in: project.filesRoot) == nil } ?? false
    }

    private func addFile(_ url: URL, config: ProjectConfig) {
        let root = realPath(project.filesRoot) + "/"
        let file = realPath(url)
        guard file.hasPrefix(root) else {
            errorMessage = "\(url.lastPathComponent) is outside \(project.name). Copy it into the repo first, or paste it as a prompt."
            return
        }
        addPath(String(file.dropFirst(root.count)), config: config)
    }

    private func addPath(_ path: String, config: ProjectConfig) {
        guard !config.docs.docs.contains(where: { $0.path == path }) else {
            errorMessage = "\(path) is already listed."
            return
        }
        var index = config.docs
        index.docs.append(DocEntry(title: (path as NSString).lastPathComponent, path: path, readers: readers))
        write(index)
    }

    private func addPrompt(config: ProjectConfig) {
        var index = config.docs
        index.docs.append(DocEntry(
            title: promptTitle.trimmingCharacters(in: .whitespaces),
            prompt: promptBody.trimmingCharacters(in: .whitespacesAndNewlines),
            readers: readers
        ))
        write(index)
        promptTitle = ""
        promptBody = ""
    }

    private func replace(at index: Int, with doc: DocEntry, in config: ProjectConfig) {
        var docs = config.docs
        guard docs.docs.indices.contains(index) else { return }
        docs.docs[index] = doc
        write(docs)
    }

    private func remove(at index: Int, in config: ProjectConfig) {
        var docs = config.docs
        guard docs.docs.indices.contains(index) else { return }
        docs.docs.remove(at: index)
        write(docs)
    }

    private func write(_ docs: DocsIndex) {
        do {
            try ProjectConfigLoader.write(docs, repository: project.filesRoot)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t save docs.yaml: \(error.localizedDescription)"
        }
        workspace.reloadConfig(for: project)
    }

    private func realPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private struct DocRow: View {
    let doc: DocEntry
    let roles: [RoleDefinition]
    let tokens: Int
    let isMissing: Bool
    let update: (DocEntry) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.path ?? doc.title)
                    .font(doc.path == nil ? .system(size: 13.5, weight: .semibold) : Tokens.mono(13.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isMissing ? Tokens.need : Tokens.text2)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach([ReaderChoice.all, .leads, .coding, .reviewers]) { choice in
                    Button(choice.title) { set(readers: reader(for: choice)) }
                }
                if !roles.isEmpty {
                    Divider()
                    ForEach(roles) { role in
                        Toggle(role.name, isOn: Binding(
                            get: { if case .roles(let ids) = doc.readers { ids.contains(role.id) } else { false } },
                            set: { isOn in toggle(role: role.id, isOn: isOn) }
                        ))
                    }
                }
            } label: {
                Text(doc.readers.summary(roles: roles).joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(width: 180, alignment: .leading)
            .help("Who reads \(doc.title)")
            SectionSwitch(label: "Use \(doc.title)", isOn: Binding(get: { doc.enabled }, set: { enabled in
                var updated = doc
                updated.enabled = enabled
                update(updated)
            }))
            .help(doc.enabled ? "Agents read this document" : "Turned off")
            Button(action: remove) {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.text3)
            .help("Remove \(doc.title) from docs.yaml")
            .accessibilityLabel("Remove \(doc.title)")
        }
    }

    private var detail: String {
        let parts = [doc.description.isEmpty ? (doc.path == nil ? "Prompt · written in Saturn" : doc.title) : doc.description,
                     isMissing ? "missing" : nil,
                     "\(String(format: "%.1f", Double(tokens) / 1000))k tokens"]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    private func reader(for choice: ReaderChoice) -> DocReaders {
        switch choice {
        case .all: .all
        case .leads: .leads
        case .coding: .coding
        case .reviewers: .reviewers
        case .roles: .all
        }
    }

    private func set(readers: DocReaders) {
        var updated = doc
        updated.readers = readers
        update(updated)
    }

    private func toggle(role: String, isOn: Bool) {
        var ids: [String] = []
        if case .roles(let current) = doc.readers { ids = current }
        if isOn {
            if !ids.contains(role) { ids.append(role) }
        } else {
            ids.removeAll { $0 == role }
        }
        set(readers: ids.isEmpty ? .all : .roles(ids))
    }
}
