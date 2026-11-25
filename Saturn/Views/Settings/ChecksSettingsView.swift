import AppKit
import SaturnCore
import SaturnUI
import SwiftUI

struct ChecksSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var suggestions: CheckSuggestions?
    @State private var report: HarnessReport?
    @State private var isCheckingHealth = false
    @State private var healthError: String?

    @State private var roundsDraft = ""

    var body: some View {
        let checks = workspace.config(for: project).checks
        SettingsPage("Checks", subtitle: "Run in every worker’s worktree before the Reviewer sees the work: format, lint, type check, tests and scans. Failures go back to the agent, never to review.") {
            if let checks, !checks.checks.isEmpty {
                configuredChecks(checks)
            } else {
                suggestedChecks
            }
            if let checks, !checks.protectedPaths.isEmpty {
                protectedCard(checks.protectedPaths)
            }
            healthCard(hasChecks: !(checks?.checks.isEmpty ?? true))
        }
        .task(id: project.id) {
            suggestions = CheckDetector.suggest(repository: project.filesRoot)
            roundsDraft = String(workspace.config(for: project).checks?.maxRounds ?? ChecksConfig.defaultMaxRounds)
        }
    }

    @ViewBuilder
    private func configuredChecks(_ checks: ChecksConfig) -> some View {
        SettingsRows {
            ForEach(Array(checks.checks.enumerated()), id: \.element.id) { index, check in
                CheckRow(index: index + 1, check: check, runsAfterEdits: Binding(
                    get: { check.onEdit },
                    set: { value in update(checks) { $0.checks[index].onEdit = value } }
                ))
            }
        }
        if !checks.hasTestCheck {
            SettingsWarning("No check of kind test, so agents’ work isn’t verified by tests.")
        }
        HStack(spacing: 24) {
            HStack(spacing: 8) {
                Text("Rounds before a worker stops").font(.system(size: 13))
                TextField("Rounds", text: $roundsDraft)
                    .sectionField(width: 52)
                    .onSubmit { saveRounds(checks) }
                    .accessibilityLabel("Rounds before a worker stops")
                    .help("Failing work goes back to its agent this many times, then to you in the chat. Press Return to save.")
            }
            Spacer(minLength: 0)
            Button("Open \(ChecksConfig.fileName)") { openChecksFile() }
                .buttonStyle(SectionButtonStyle())
                .help("Edit the checks in your editor; Saturn reloads them when you come back")
            Button("Reload") { workspace.reloadConfig(for: project) }
                .buttonStyle(SectionButtonStyle())
        }
        SettingsNote("The switch runs a check after every edit as well as before review.", color: Tokens.text3)
    }

    @ViewBuilder
    private var suggestedChecks: some View {
        SettingsRows {
            SettingsRowLabel(title: "No checks yet", detail: "Nothing verifies agents’ work before you review it.")
            if let suggestions, !suggestions.checks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsNote("Suggested from \(suggestions.evidence.joined(separator: ", ")):")
                    ForEach(Array(suggestions.checks.enumerated()), id: \.element.id) { index, check in
                        CheckRow(index: index + 1, check: check, runsAfterEdits: nil)
                    }
                    if !suggestions.protectedPaths.isEmpty {
                        Text("Protected test files: " + suggestions.protectedPaths.joined(separator: ", "))
                            .font(Tokens.mono(12))
                            .foregroundStyle(Tokens.text2)
                    }
                    if !suggestions.hasTestCheck {
                        SettingsWarning("Saturn found no test command to run. Add one to \(ChecksConfig.fileName) after adding these.")
                    }
                    Button("Add These Checks") { add(suggestions) }
                        .buttonStyle(SectionButtonStyle(kind: .primary))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsWarning("Saturn couldn’t find a test, lint or format command in this project. Add them to \(ProjectConfig.directoryName)/\(ChecksConfig.fileName).")
                    Button("Create \(ChecksConfig.fileName)") { add(CheckSuggestions(checks: [], protectedPaths: [], evidence: [])) }
                        .buttonStyle(SectionButtonStyle())
                }
            }
        }
    }

    private func protectedCard(_ paths: [String]) -> some View {
        SettingsRows {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRowLabel(title: "Protected files", detail: "Agents can’t edit existing files that match these patterns; they can add new ones. Any change that gets through is pinned for you with the test-change tag.")
                FlowLayout(spacing: 6) {
                    ForEach(paths, id: \.self) { path in CommandChip(text: path) }
                }
            }
        }
    }

    private func healthCard(hasChecks: Bool) -> some View {
        SettingsRows {
            HStack(spacing: 14) {
                SettingsRowLabel(title: "Health check", detail: "Runs the setup script and every check in a fresh worktree of the current branch, so you know agents can get them green.")
                if isCheckingHealth { ProgressView().controlSize(.small) }
                Button("Run Health Check") { runHealthCheck() }
                    .buttonStyle(SectionButtonStyle())
                    .disabled(isCheckingHealth || !hasChecks)
            }
            if let healthError {
                SettingsWarning(healthError)
            }
            if let report {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.results) { result in
                        HStack(spacing: 8) {
                            StatusDot(result.passed ? Tokens.done : Tokens.danger)
                            Text(result.headline).font(.system(size: 12.5))
                            Spacer()
                            Text(result.durationSeconds.formatted(.number.precision(.fractionLength(1))) + " s")
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text2)
                        }
                    }
                    if report.isHealthy {
                        SettingsNote("Everything passes on a clean checkout.", color: Tokens.done)
                    } else {
                        ForEach(report.problems, id: \.self) { SettingsWarning($0) }
                    }
                }
            }
        }
    }

    private func saveRounds(_ checks: ChecksConfig) {
        guard let rounds = Int(roundsDraft.trimmingCharacters(in: .whitespaces)), (1...20).contains(rounds) else {
            roundsDraft = String(checks.maxRounds)
            return
        }
        update(checks) { $0.maxRounds = rounds }
    }

    private func update(_ checks: ChecksConfig, _ change: (inout ChecksConfig) -> Void) {
        var updated = checks
        change(&updated)
        do {
            try ProjectConfigLoader.write(updated, repository: project.filesRoot)
        } catch {
            model.alert = AppAlert(title: "Couldn’t write \(ChecksConfig.fileName)", message: error.localizedDescription)
        }
        workspace.reloadConfig(for: project)
    }

    private func add(_ suggestions: CheckSuggestions) {
        do {
            try ProjectConfigLoader.write(suggestions.config, repository: project.filesRoot)
        } catch {
            model.alert = AppAlert(title: "Couldn’t write \(ChecksConfig.fileName)", message: error.localizedDescription)
        }
        workspace.reloadConfig(for: project)
    }

    private func openChecksFile() {
        NSWorkspace.shared.open(ChecksConfig.file(in: project.filesRoot))
    }

    private func runHealthCheck() {
        guard let git = workspace.git(for: project) else {
            healthError = "git isn’t available."
            return
        }
        isCheckingHealth = true
        healthError = nil
        Task {
            defer { isCheckingHealth = false }
            do {
                report = try await workspace.send(ProjectCommands.CheckHarness(projectID: project.id ?? -1))
            } catch {
                healthError = error.localizedDescription
            }
        }
    }
}

private struct CheckRow: View {
    let index: Int
    let check: CheckDefinition
    let runsAfterEdits: Binding<Bool>?

    var body: some View {
        HStack(spacing: 14) {
            Text("\(index)")
                .font(Tokens.mono(12))
                .foregroundStyle(Tokens.text3)
                .frame(width: 14, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(check.kind.rawValue).font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
            }
            .frame(width: 100, alignment: .leading)
            Text(check.command)
                .font(Tokens.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.code, in: .rect(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.hair))
                .help(check.command)
            Text("\(check.timeoutMinutes) min limit")
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text2)
                .frame(width: 84, alignment: .leading)
            if let runsAfterEdits {
                SectionSwitch(label: "Run \(check.name) after every edit", isOn: runsAfterEdits)
                    .help(runsAfterEdits.wrappedValue ? "Runs after every edit and before review" : "Runs before review only")
            }
        }
    }
}

struct CommandChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.mono(12))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Tokens.code, in: .rect(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Tokens.hair))
            .textSelection(.enabled)
    }
}
