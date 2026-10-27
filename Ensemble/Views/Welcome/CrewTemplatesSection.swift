import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct CrewTemplatesSection: View {
    @Environment(AppModel.self) private var model
    @State private var templates: [CrewTemplate] = []
    @State private var chosen: CrewTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { heading }
                VStack(alignment: .leading, spacing: 4) { heading }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(templates) { template in
                    TemplateCard(template: template) { chosen = template }
                }
            }
        }
        .task { templates = CrewTemplates.bundled }
        .confirmationDialog(
            "Start with the \(chosen?.name ?? "") crew",
            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
            presenting: chosen
        ) { template in
            Button("Create New Folder…") { createNewFolder(for: template) }
            Button("Use Existing Repository…") { chooseExistingFolder(for: template) }
            Button("Cancel", role: .cancel) {}
        } message: { template in
            Text("Adds \(template.roles.count) roles and the \(template.workflows.joined(separator: ", ")) workflow to .ensemble/, then opens the project. A new folder gets git init and a first commit.")
        }
    }

    @ViewBuilder
    private var heading: some View {
        SectionLabel("Start with a crew template")
        Text("Adds roles, checks and a workflow. Agents are only created when a task needs them")
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiaryText)
    }

    private func createNewFolder(for template: CrewTemplate) {
        let panel = NSSavePanel()
        panel.title = "New \(template.name) Project"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "my-project"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.createProject(from: template, at: url) }
        }
    }

    private func chooseExistingFolder(for template: CrewTemplate) {
        let panel = NSOpenPanel()
        panel.title = "Add the \(template.name) Crew"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.applyTemplate(template, toExisting: url) }
        }
    }
}

private struct TemplateCard: View {
    let template: CrewTemplate
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CrewStack(palettes: template.crewRoles.map(\.palette), size: 26, border: Color(hex: 0x232327))
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name).font(.system(size: 13.5, weight: .semibold))
                    Text(template.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(template.workflows.map { $0.replacingOccurrences(of: "-", with: " ").capitalizedFirst }.joined(separator: " + "))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.link)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(isHovered ? 0.07 : 0.045), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Set up a project with the \(template.name) roles and workflow")
        .accessibilityLabel("\(template.name) crew template")
        .accessibilityHint(template.description)
    }
}

struct CrewStack: View {
    static let maximumShown = 7

    let palettes: [RolePalette]
    var size: CGFloat = 22
    var border: Color = Theme.windowBackground

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(palettes.prefix(Self.maximumShown).enumerated()), id: \.offset) { _, palette in
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(palette.gradient)
                    .frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(border, lineWidth: 2))
            }
            if palettes.count > Self.maximumShown {
                Text("+\(palettes.count - Self.maximumShown)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 10)
            }
        }
        .padding(.leading, 6)
        .accessibilityHidden(true)
    }
}

extension RoleDefinition {
    var palette: RolePalette { RolePalette(rawValue: color) ?? .neutral }
}
