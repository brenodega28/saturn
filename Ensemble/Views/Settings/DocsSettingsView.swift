import AppKit
import EnsembleCore
import EnsembleUI
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
    let project: Project

    @State private var mode = Mode.file
    @State private var readerChoice = ReaderChoice.all
    @State private var chosenRoles: Set<String> = []
    @State private var promptTitle = ""
    @State private var promptBody = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable, Identifiable {
        case file
        case prompt

        var id: Self { self }
        var title: String { self == .file ? "From file" : "Write a prompt" }
    }

    var body: some View {
        let config = model.config(for: project)
        let docs = config.docs.docs
        SettingsPage("Documentation", subtitle: "Context your agents read before they work. Link a file from the repo to keep it in sync, or write a prompt that lives in .ensemble/docs.yaml.") {
            addCard(config: config)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            IssueList(issues: config.issues.filter { $0.file.hasSuffix("docs.yaml") })
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("In this project").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(docs.filter(\.enabled).count) of \(docs.count) in use")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(16)
                if docs.isEmpty {
                    Text("No documents yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .padding([.horizontal, .bottom], 16)
                }
                ForEach(Array(docs.enumerated()), id: \.offset) { index, doc in
                    Divider().overlay(Theme.hairline)
                    DocRow(doc: doc, roles: config.roles, tokens: tokens(for: doc), isMissing: isMissing(doc), update: { updated in
                        replace(at: index, with: updated, in: config)
                    }, remove: {
                        remove(at: index, in: config)
                    })
                }
            }
            .card(cornerRadius: 16)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text, .pdf, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { addFile(url, config: model.config(for: project)) }
            }
        }
    }

    private func addCard(config: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add a document").font(.system(size: 15, weight: .semibold)).lineLimit(1)
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
                    Text("Files inside the repo stay linked: agents read the current version on every turn.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Button("Choose File…") { isImporting = true }
                        .buttonStyle(.pill)
                        .help("Pick a file inside \(project.name)")
                    let suggestions = suggestedFiles(config: config)
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: 6) {
                            Text("Found in repo, not added yet:")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                            ForEach(suggestions, id: \.self) { path in
                                Button("+ \(path)") { addPath(path, config: config) }
                                    .buttonStyle(.link)
                                    .font(.system(size: 12, design: .monospaced))
                                    .help("Add \(path)")
                            }
                        }
                    }
                }
            case .prompt:
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: $promptTitle, prompt: Text("e.g. Payments rules"))
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $promptBody)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110)
                        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                        .accessibilityLabel("Prompt")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Who reads it").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                FlowLayout(spacing: 8) {
                    readerChips(config: config)
                }
            }

            if mode == .prompt {
                HStack {
                    Spacer()
                    Button("Add Prompt") { addPrompt(config: config) }
                        .buttonStyle(.primaryPill)
                        .disabled(promptTitle.trimmingCharacters(in: .whitespaces).isEmpty || promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
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
                .background(readerChoice == choice ? Theme.accent.opacity(0.16) : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(readerChoice == choice ? Theme.accent : Color.white.opacity(0.1)))
            } else {
                Button(choice.title) { readerChoice = choice }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(readerChoice == choice ? Theme.accent.opacity(0.16) : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(readerChoice == choice ? Theme.accent : Color.white.opacity(0.1)))
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
        let docsFolder = project.url.appending(path: "docs")
        if let files = try? fileManager.contentsOfDirectory(atPath: docsFolder.path) {
            candidates += files.filter { $0.lowercased().hasSuffix(".md") }.sorted().map { "docs/\($0)" }
        }
        return candidates.filter { !added.contains($0) && fileManager.fileExists(atPath: project.url.appending(path: $0).path) }
    }

    private func tokens(for doc: DocEntry) -> Int {
        if let path = doc.path {
            guard let file = SkillLibrary.file(path, in: project.url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { return 0 }
            return min(size, RoleContext.defaultDocumentLimit) / 4
        }
        return TokenEstimate.of(doc.prompt ?? "")
    }

    private func isMissing(_ doc: DocEntry) -> Bool {
        doc.path.map { SkillLibrary.file($0, in: project.url) == nil } ?? false
    }

    private func addFile(_ url: URL, config: ProjectConfig) {
        let root = realPath(project.url) + "/"
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
            try ProjectConfigLoader.write(docs, repository: project.url)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t save docs.yaml: \(error.localizedDescription)"
        }
        model.reloadConfig(for: project)
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
        HStack(alignment: .center, spacing: 12) {
            Text(fileExtension)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(doc.path == nil ? Theme.secondaryText : Color(hex: 0x7DB6FF))
                .frame(width: 36, height: 36)
                .background(doc.path == nil ? Theme.fillRaised : Theme.accent.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title).font(.system(size: 13.5, weight: .semibold))
                if !doc.description.isEmpty {
                    Text(doc.description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                HStack(spacing: 6) {
                    StatusDot(isMissing ? Theme.warning : (doc.path == nil ? Theme.neutral : Theme.success), size: 6)
                    Text(source).lineLimit(1).truncationMode(.middle)
                    Text("·").accessibilityHidden(true)
                    Text("\(String(format: "%.1f", Double(tokens) / 1000))k tokens").fixedSize()
                }
                .font(.system(size: 11.5))
                .foregroundStyle(isMissing ? Theme.warning : Theme.tertiaryText)
            }
            Spacer(minLength: 8)
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
                HStack(spacing: 4) {
                    ForEach(readerLabels, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.fillRaised, in: Capsule())
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Who reads \(doc.title)")
            Toggle("Use \(doc.title)", isOn: Binding(get: { doc.enabled }, set: { enabled in
                var updated = doc
                updated.enabled = enabled
                update(updated)
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(doc.enabled ? "Agents read this document" : "Turned off")
            Button(action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Remove \(doc.title) from docs.yaml")
            .accessibilityLabel("Remove \(doc.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(doc.enabled ? 1 : 0.55)
    }

    private var readerLabels: [String] {
        let names = doc.readers.summary(roles: roles)
        guard names.count > 2 else { return names }
        return Array(names.prefix(1)) + ["+\(names.count - 1)"]
    }

    private var fileExtension: String {
        guard let path = doc.path else { return "TXT" }
        let ext = (path as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }

    private var source: String {
        if let path = doc.path {
            return isMissing ? "\(path) · missing" : path
        }
        return "Prompt · written in Ensemble"
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
