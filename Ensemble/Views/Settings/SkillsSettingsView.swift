import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct SkillsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let project: Project
    @State private var marketplace = ""
    @State private var plugin = ""
    @State private var isInstalling = false
    @State private var installMessage: String?
    @State private var installError: String?
    @State private var hasUncommittedSettings = false

    var body: some View {
        let plugins = project.id.flatMap { workspace.skillPlugins[$0] } ?? []
        let skills = SkillLibrary.skills(in: project.filesRoot, pluginSkills: workspace.pluginSkills(for: project))
        SettingsPage("Skills", subtitle: "Skills installed for this project, from .claude/skills, the project’s plugins and ~/.claude/skills. The Lead chooses which skills each builder or checker loads; Ensemble never turns them on for every agent.") {
            installCard(plugins: plugins)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Installed skills")
                    Spacer()
                    Text("\(skills.count)")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(16)
                if skills.isEmpty {
                    Divider().overlay(Theme.hairline)
                    Text("No skills yet. Add a folder with a SKILL.md to .claude/skills or ~/.claude/skills, or install a plugin above.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
                ForEach(skills) { skill in
                    Divider().overlay(Theme.hairline)
                    skillRow(skill)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 16)
        }
    }

    private func skillRow(_ skill: InstalledSkill) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(skill.source.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.fillRaised, in: .capsule)
                .help("From \(skill.source.location)")
        }
    }

    private func installCard(plugins: [SkillPlugin]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install skills").font(.system(size: 13.5, weight: .semibold))
                Text("Adds a plugin marketplace and installs a plugin with Claude Code, for this project only. Agents load plugins enabled in \(SkillPluginInstaller.settingsPath).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) {
                    marketplaceField.frame(minWidth: 200)
                    pluginField.frame(minWidth: 160)
                    installButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    marketplaceField
                    pluginField
                    installButton
                }
            }
            if let installMessage {
                Text(installMessage).font(.system(size: 12)).foregroundStyle(Theme.successText)
            }
            if let installError {
                Text(installError)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if hasUncommittedSettings {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Not committed")
                    Text("Commit \(SkillPluginInstaller.settingsPath). Coding agents work in worktrees made from commits, so they only get plugins once it’s committed.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plugins.isEmpty {
                Divider().overlay(Theme.hairline)
                ForEach(plugins) { plugin in
                    DisclosureGroup {
                        FlowLayout(spacing: 6) {
                            ForEach(plugin.skills, id: \.self) { skill in
                                SkillChip(name: skill, isMissing: false)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Text(plugin.id).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            Text(plugin.skills.count == 1 ? "1 skill" : "\(plugin.skills.count) skills")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
        .task(id: project.path) { await refreshPlugins() }
    }

    private var marketplaceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marketplace").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            TextField("Marketplace", text: $marketplace, prompt: Text("getsentry/skills"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .help("A GitHub owner/repo, a git or https URL, or a local path")
        }
    }

    private var pluginField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plugin").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            TextField("Plugin", text: $plugin, prompt: Text("sentry-skills"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .onSubmit { Task { await install() } }
                .help("The plugin’s name in that marketplace, or plugin@marketplace")
        }
    }

    private var installButton: some View {
        HStack(spacing: 8) {
            Button("Install") { Task { await install() } }
                .buttonStyle(.primaryPill)
                .disabled(isInstalling || marketplace.trimmingCharacters(in: .whitespaces).isEmpty || plugin.trimmingCharacters(in: .whitespaces).isEmpty)
            if isInstalling {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        installMessage = nil
        installError = nil
        defer { isInstalling = false }
        do {
            let installed = try await workspace.installSkillPlugin(plugin, from: marketplace, in: project)
            installMessage = "Installed \(installed.id) with \(installed.skills.count == 1 ? "1 skill" : "\(installed.skills.count) skills"). The Lead can now give them to agents."
            marketplace = ""
            plugin = ""
        } catch {
            installError = error.localizedDescription
        }
        hasUncommittedSettings = await workspace.hasUncommittedSkillSettings(in: project)
    }

    private func refreshPlugins() async {
        do {
            try await workspace.loadSkillPlugins(for: project)
        } catch {
            installError = "Couldn’t list this project’s plugins: \(error.localizedDescription)"
        }
        hasUncommittedSettings = await workspace.hasUncommittedSkillSettings(in: project)
    }

}

private struct SkillChip: View {
    let name: String
    let isMissing: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).accessibilityLabel("Missing")
            }
            Text(name).font(.system(size: 12, design: .monospaced))
        }
        .foregroundStyle(isMissing ? Color(hex: 0xFFC36B) : Theme.primaryText)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isMissing ? Theme.warning.opacity(0.1) : Color.black.opacity(0.25), in: .rect(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isMissing ? Theme.warning.opacity(0.4) : Tokens.hair2))
        .help(isMissing ? "\(name) isn’t in .claude/skills or an installed plugin" : name)
    }
}
