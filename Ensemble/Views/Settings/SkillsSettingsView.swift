import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct SkillsSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var tableWidth: CGFloat = 0

    static let roleColumnMinimumTableWidth: CGFloat = 520

    var body: some View {
        let config = model.config(for: project)
        let installed = SkillLibrary.installedSkills(in: project.url)
        let manifest = project.url.appending(path: SkillLibrary.manifestPath)
        let hasManifest = FileManager.default.fileExists(atPath: manifest.path)
        SettingsPage("Skills", subtitle: "Skills each role loads from .claude/skills. Claude Code reads the skill files itself; Ensemble tells each agent which ones to use.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Write the rules below to \(SkillLibrary.manifestPath) so they are versioned with the code.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(hasManifest ? "Update SKILLS.md" : "Write SKILLS.md") { writeManifest(config) }
                        .buttonStyle(.primaryPill)
                        .help("Writes \(SkillLibrary.manifestPath) from the roles in .ensemble/roles")
                    if hasManifest {
                        Button("Open SKILLS.md") { NSWorkspace.shared.open(manifest) }
                            .buttonStyle(.pill)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 16)

            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.successText)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.danger).textSelection(.enabled)
            }

            let hasRoleColumn = tableWidth >= Self.roleColumnMinimumTableWidth
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if hasRoleColumn {
                        Text("Role").frame(width: 200, alignment: .leading)
                        Text("Skills")
                    } else {
                        Text("Role and skills")
                    }
                    Spacer()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(16)
                ForEach(config.roles) { role in
                    Divider().overlay(Theme.hairline)
                    Group {
                        if hasRoleColumn {
                            HStack(alignment: .center, spacing: 0) {
                                roleName(role).frame(width: 200, alignment: .leading)
                                skills(of: role, installed: installed)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                roleName(role)
                                skills(of: role, installed: installed)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(cornerRadius: 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }

            let missing = missingSkills(config: config, installed: installed)
            ForEach(missing, id: \.skill) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityLabel("Missing skill")
                    Text("\(item.skill) is listed for \(item.roles.joined(separator: ", ")) but isn’t in .claude/skills. Those agents start without it.")
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warning.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
            }

            Text(installed.isEmpty
                 ? "No skills in .claude/skills yet."
                 : "In .claude/skills: \(installed.sorted().joined(separator: ", "))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Text("Change which skills a role uses in Settings › Roles.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func roleName(_ role: RoleDefinition) -> some View {
        HStack(spacing: 10) {
            AgentAvatar(size: 26, appearance: RoleAppearance(role: role))
            Text(role.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
    }

    @ViewBuilder
    private func skills(of role: RoleDefinition, installed: Set<String>) -> some View {
        if role.skills.isEmpty {
            Text("No skills")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(role.skills, id: \.self) { skill in
                    SkillChip(name: skill, isMissing: !installed.contains(skill))
                }
            }
        }
    }

    private func missingSkills(config: ProjectConfig, installed: Set<String>) -> [(skill: String, roles: [String])] {
        var order: [String] = []
        var roles: [String: [String]] = [:]
        for role in config.roles {
            for skill in role.skills where !installed.contains(skill) {
                if roles[skill] == nil { order.append(skill) }
                roles[skill, default: []].append(role.name)
            }
        }
        return order.map { ($0, roles[$0] ?? []) }
    }

    private func writeManifest(_ config: ProjectConfig) {
        do {
            let file = try SkillLibrary.writeManifest(for: config, repository: project.url)
            message = "Wrote \(file.lastPathComponent) at \(SkillLibrary.manifestPath)."
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t write \(SkillLibrary.manifestPath): \(error.localizedDescription)"
        }
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
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isMissing ? Theme.warning.opacity(0.4) : Color.white.opacity(0.1)))
        .help(isMissing ? "\(name) isn’t in .claude/skills" : name)
    }
}
