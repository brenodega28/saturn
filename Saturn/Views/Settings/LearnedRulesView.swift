import AppKit
import SaturnCore
import SaturnUI
import SwiftUI

struct LearnedRulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var corrections: [Correction] = []
    @State private var repeated: Set<Int64> = []
    @State private var encoding: Correction?
    @State private var status = AgentInstructionsStatus(hasAgentsFile: false, claudePointsToAgents: false, lineCount: 0, characterCount: 0)
    @State private var message: String?

    var body: some View {
        SettingsPage("Learned rules", subtitle: "Every change you request in review is kept here. Encode the ones that keep coming back as a line in AGENTS.md, a check or a protected path, so agents stop repeating them.") {
            instructionsCard
            correctionsCard
        }
        .task(id: project.id) { reload() }
        .sheet(item: $encoding) { correction in
            EncodeCorrectionSheet(project: project, correction: correction) { reload() }
        }
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AgentInstructions.fileName).font(.system(size: 15, weight: .semibold))
                Spacer()
                if status.hasAgentsFile {
                    Button("Open") { NSWorkspace.shared.open(project.filesRoot.appending(path: AgentInstructions.fileName)) }
                        .buttonStyle(.pill)
                }
                if !status.isSetUp {
                    Button(status.hasAgentsFile ? "Point CLAUDE.md at It" : "Set Up AGENTS.md") { setUpInstructions() }
                        .buttonStyle(.pill)
                        .help("Writes AGENTS.md (or moves CLAUDE.md into it), points CLAUDE.md at it and commits both")
                }
            }
            Text(status.hasAgentsFile
                ? "\(status.lineCount) lines. Agents read it through CLAUDE.md\(status.claudePointsToAgents ? "" : ", which doesn’t point to it yet")."
                : "The one short file every agent reads: exact commands, non-default conventions and gotchas. Nothing agents can work out from the code.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if status.isTooLong {
                Label("It’s longer than a page. Long instruction files get ignored: move rules that matter into checks or protected paths, and cut what agents can infer.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private var correctionsCard: some View {
        let open = corrections.filter { !$0.isEncoded }.sorted { repeated.contains($0.id ?? -1) && !repeated.contains($1.id ?? -1) }
        let encoded = corrections.filter(\.isEncoded)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Your corrections").font(.system(size: 15, weight: .semibold))
            if open.isEmpty {
                Text("Nothing to encode. Corrections show up here when you request a change or comment in Changes.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(open) { correction in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(correction.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Text([correction.file, correction.createdAt.formatted(date: .abbreviated, time: .omitted)].compactMap(\.self).joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer()
                    if repeated.contains(correction.id ?? -1) {
                        Text("Repeated").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
                    }
                    Button("Encode…") { encoding = correction }
                        .buttonStyle(.pill)
                }
            }
            if !encoded.isEmpty {
                Divider().overlay(Tokens.hair)
                Text("Encoded").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                ForEach(encoded) { correction in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(correction.text).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                        Text(correction.encoding ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }

    private func reload() {
        guard let id = project.id else { return }
        corrections = (try? workspace.database.corrections(projectId: id)) ?? []
        repeated = (try? workspace.database.repeatedCorrections(projectId: id)) ?? []
        status = AgentInstructions.status(repository: project.filesRoot)
    }

    private func setUpInstructions() {
        guard let git = workspace.git(for: project) else { return }
        Task {
            do {
                let written = try AgentInstructions.setUp(repository: project.filesRoot)
                if !written.isEmpty {
                    try await workspace.syncRemoteFiles(project)
                    try await AgentInstructions.commit(written, message: "Set up AGENTS.md for coding agents", repository: project.url, git: git)
                }
                message = written.isEmpty ? nil : "Committed \(written.joined(separator: " and "))."
            } catch {
                message = "Couldn’t set up AGENTS.md: \(error.localizedDescription)"
            }
            reload()
        }
    }
}

private struct EncodeCorrectionSheet: View {
    enum Target: String, CaseIterable, Identifiable {
        case instruction = "Line in AGENTS.md"
        case check = "Check"
        case protectedPath = "Protected path"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let correction: Correction
    let done: () -> Void
    @State private var target: Target = .instruction
    @State private var instruction = ""
    @State private var checkName = ""
    @State private var checkCommand = ""
    @State private var checkKind: CheckKind = .lint
    @State private var protectedPath = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Encode this correction").font(.system(size: 16, weight: .semibold))
            Text("“\(correction.text)”").font(.system(size: 13)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Picker("Encode as", selection: $target) {
                ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch target {
            case .instruction:
                TextField("Rule", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Text("Added under “Learned from review” in AGENTS.md. Keep it one line an agent can act on.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            case .check:
                TextField("Name", text: $checkName).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $checkKind) {
                    ForEach(CheckKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Command", text: $checkCommand).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                Text("Added to \(ProjectConfig.directoryName)/\(ChecksConfig.fileName); it runs on every branch from now on.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            case .protectedPath:
                TextField("Glob", text: $protectedPath).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                Text("Agents can’t edit existing files that match it, and any change that gets through is pinned for you.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Commit") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !isValid)
            }
            Text("Saturn commits only the changed file to \(project.name)’s current branch.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            let suggestions = CorrectionEncoding.suggestions(for: correction)
            instruction = suggestions.instruction
            protectedPath = suggestions.protectedPath ?? ""
        }
    }

    private var encoding: CorrectionEncoding? {
        switch target {
        case .instruction:
            let line = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : .instruction(line)
        case .check:
            let name = checkName.trimmingCharacters(in: .whitespaces), command = checkCommand.trimmingCharacters(in: .whitespaces)
            return name.isEmpty || command.isEmpty ? nil : .check(CheckDefinition(name: name, kind: checkKind, command: command))
        case .protectedPath:
            let glob = protectedPath.trimmingCharacters(in: .whitespaces)
            return glob.isEmpty || glob.hasPrefix("/") ? nil : .protectedPath(glob)
        }
    }

    private var isValid: Bool { encoding != nil }

    private func commit() {
        guard let encoding, let correctionID = correction.id else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await workspace.syncRemoteFiles(project)
                try await workspace.send(CodeCommands.EncodeCorrection(correctionID: correctionID, encoding: encoding))
                try await workspace.pullRemoteFiles(project)
                workspace.reloadConfig(for: project)
                done()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
