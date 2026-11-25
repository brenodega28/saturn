import AppKit
import SaturnCore
import SaturnUI
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
    @State private var isAdding = false

    var body: some View {
        let plugins = project.id.flatMap { workspace.skillPlugins[$0] } ?? []
        let skills = SkillLibrary.skills(in: project.filesRoot, pluginSkills: workspace.pluginSkills(for: project))
        SettingsPage("Skills", subtitle: "Extra know-how agents can load when the task calls for it, from .claude/skills, the project’s plugins and ~/.claude/skills. The Lead chooses which skills each worker loads; Saturn never turns them on for every agent.") {
            if skills.isEmpty {
                SettingsRows {
                    SettingsRowLabel(title: "No skills yet", detail: "Add a folder with a SKILL.md to .claude/skills or ~/.claude/skills, or install a plugin.")
                }
            } else {
                SettingsRows {
                    ForEach(skills) { skill in skillRow(skill) }
                }
            }
            if isAdding || skills.isEmpty || !plugins.isEmpty || installError != nil {
                installCard(plugins: plugins)
            } else {
                Button("+ Add a skill") { isAdding = true }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .task(id: project.path) { await refreshPlugins() }
    }

    private func skillRow(_ skill: InstalledSkill) -> some View {
        HStack(spacing: 14) {
            SettingsRowLabel(title: skill.name, detail: skill.description, monospaced: true)
            Text(skill.source.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text2)
                .frame(width: 180, alignment: .leading)
                .help("From \(skill.source.location)")
        }
    }

    private func installCard(plugins: [SkillPlugin]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a skill").font(.system(size: 14, weight: .semibold))
                SettingsNote("Adds a plugin marketplace and installs a plugin with Claude Code, for this project only. Agents load plugins enabled in \(SkillPluginInstaller.settingsPath).")
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
                Text(installMessage).font(.system(size: 12)).foregroundStyle(Tokens.done)
            }
            if let installError {
                Text(installError)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if hasUncommittedSettings {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.need)
                        .accessibilityLabel("Not committed")
                    Text("Commit \(SkillPluginInstaller.settingsPath). Coding agents work in worktrees made from commits, so they only get plugins once it’s committed.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plugins.isEmpty {
                Rectangle().fill(Tokens.hair).frame(height: 1)
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
                            Text(plugin.id).font(Tokens.mono(12.5, weight: .medium))
                            Text(plugin.skills.count == 1 ? "1 skill" : "\(plugin.skills.count) skills")
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text2)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionCard()
    }

    private var marketplaceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Marketplace").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
            TextField("Marketplace", text: $marketplace, prompt: Text("getsentry/skills"))
                .sectionField(width: nil, monospaced: true)
                .labelsHidden()
                .autocorrectionDisabled()
                .help("A GitHub owner/repo, a git or https URL, or a local path")
        }
    }

    private var pluginField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plugin").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
            TextField("Plugin", text: $plugin, prompt: Text("sentry-skills"))
                .sectionField(width: nil, monospaced: true)
                .labelsHidden()
                .autocorrectionDisabled()
                .onSubmit { Task { await install() } }
                .help("The plugin’s name in that marketplace, or plugin@marketplace")
        }
    }

    private var installButton: some View {
        HStack(spacing: 8) {
            Button("Install") { Task { await install() } }
                .buttonStyle(SectionButtonStyle(kind: .primary, height: 32))
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
            Text(name).font(Tokens.mono(12))
        }
        .foregroundStyle(isMissing ? Tokens.need : Tokens.text)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(isMissing ? Tokens.needBackground : Tokens.code, in: .rect(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isMissing ? Tokens.needLine : Tokens.hair))
        .help(isMissing ? "\(name) isn’t in .claude/skills or an installed plugin" : name)
    }
}
