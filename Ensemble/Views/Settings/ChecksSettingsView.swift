import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct ChecksSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var suggestions: CheckSuggestions?
    @State private var report: HarnessReport?
    @State private var isCheckingHealth = false
    @State private var healthError: String?

    var body: some View {
        let checks = workspace.config(for: project).checks
        SettingsPage("Checks", subtitle: "Commands Ensemble runs on every agent’s worktree before work reaches you: format, lint, type check, tests and scans. Failures go back to the agent, never to review.") {
            checksCard(checks)
            if let checks, !checks.protectedPaths.isEmpty {
                protectedCard(checks.protectedPaths)
            }
            healthCard(hasChecks: !(checks?.checks.isEmpty ?? true))
        }
        .task(id: project.id) {
            suggestions = CheckDetector.suggest(repository: project.filesRoot)
        }
    }

    @ViewBuilder
    private func checksCard(_ checks: ChecksConfig?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Checks").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Open \(ChecksConfig.fileName)") { openChecksFile() }
                    .buttonStyle(.pill)
                    .disabled(checks == nil)
                    .help("Edit the checks in your editor; Ensemble reloads them when you come back")
                Button("Reload") { workspace.reloadConfig(for: project) }
                    .buttonStyle(.pill)
            }
            if let checks, !checks.checks.isEmpty {
                ForEach(checks.checks) { check in
                    CheckRow(check: check)
                }
                if !checks.hasTestCheck {
                    warning("No check of kind test, so agents’ work isn’t verified by tests.")
                }
                Text("Failing work goes back to its agent up to \(checks.maxRounds) round\(checks.maxRounds == 1 ? "" : "s"), then to you in the chat.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("No checks yet, so nothing verifies agents’ work before you review it.")
                    .font(.system(size: 13))
                if let suggestions, !suggestions.checks.isEmpty {
                    Text("Suggested from \(suggestions.evidence.joined(separator: ", ")):")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    ForEach(suggestions.checks) { check in
                        CheckRow(check: check)
                    }
                    if !suggestions.protectedPaths.isEmpty {
                        Text("Protected test files: " + suggestions.protectedPaths.joined(separator: ", "))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if !suggestions.hasTestCheck {
                        warning("Ensemble found no test command to run. Add one to \(ChecksConfig.fileName) after adding these.")
                    }
                    Button("Add These Checks") { add(suggestions) }
                        .buttonStyle(.pill)
                } else {
                    warning("Ensemble couldn’t find a test, lint or format command in this project. Add them to \(ProjectConfig.directoryName)/\(ChecksConfig.fileName).")
                    Button("Create \(ChecksConfig.fileName)") { add(CheckSuggestions(checks: [], protectedPaths: [], evidence: [])) }
                        .buttonStyle(.pill)
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func protectedCard(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Protected files").font(.system(size: 15, weight: .semibold))
            Text("Agents can’t edit existing files that match these patterns; they can add new ones. Any change that gets through is pinned for you with the test-change tag.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(paths.joined(separator: "\n"))
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }

    private func healthCard(hasChecks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Health check").font(.system(size: 15, weight: .semibold))
                Spacer()
                if isCheckingHealth { ProgressView().controlSize(.small) }
                Button("Run Health Check") { runHealthCheck() }
                    .buttonStyle(.pill)
                    .disabled(isCheckingHealth || !hasChecks)
            }
            Text("Runs the setup script and every check in a fresh worktree of the current branch, so you know agents can get them green.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let healthError {
                warning(healthError)
            }
            if let report {
                ForEach(report.results) { result in
                    HStack(spacing: 8) {
                        StatusDot(result.passed ? Theme.success : Theme.danger)
                        Text(result.headline).font(.system(size: 12.5))
                        Spacer()
                        Text(result.durationSeconds.formatted(.number.precision(.fractionLength(1))) + "s")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                if report.isHealthy {
                    Text("Everything passes on a clean checkout.").font(.system(size: 12.5)).foregroundStyle(Theme.successText)
                } else {
                    ForEach(report.problems, id: \.self) { warning($0) }
                }
            }
        }
        .padding(16)
        .card(cornerRadius: 16)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
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
    let check: CheckDefinition

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(check.kind.rawValue)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Tokens.fill2, in: .capsule)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).font(.system(size: 13, weight: .medium))
                Text(check.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
            }
            Spacer()
            if check.onEdit {
                Text("after edits").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
            Text("\(check.timeoutMinutes) min").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
        }
    }
}
