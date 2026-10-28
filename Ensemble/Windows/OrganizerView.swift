import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

enum OrganizerSection: String, Hashable, CaseIterable {
    case allRuns
    case failedRuns
    case usage
    case quality
    case skills
    case workflows

    var title: String {
        switch self {
        case .allRuns: "All runs"
        case .failedRuns: "Failed runs"
        case .usage: "Usage"
        case .quality: "Quality"
        case .skills: "Skills"
        case .workflows: "Workflows"
        }
    }

    var systemImage: String {
        switch self {
        case .allRuns: "play.circle"
        case .failedRuns: "exclamationmark.triangle"
        case .usage: "dollarsign"
        case .quality: "chart.bar"
        case .skills: "sparkles"
        case .workflows: "flowchart"
        }
    }
}

struct OrganizerRunRow: Identifiable, Hashable {
    let run: Run
    let projectName: String
    let checkRounds: String

    var id: Int64 { run.id ?? -1 }
}

struct OrganizerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var section: OrganizerSection = .allRuns
    @State private var query = ""
    @State private var projectFilter: Int64?
    @State private var rows: [OrganizerRunRow] = []

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let value = $0 { section = value } })) {
                Section("Work") {
                    row(.allRuns, count: rows.count)
                    row(.failedRuns, count: rows.filter { $0.run.status == .failed }.count)
                }
                Section("Insights") {
                    row(.usage)
                    row(.quality)
                }
                Section("Templates") {
                    row(.skills, count: ProjectSetup.skillCatalog.count)
                    row(.workflows, count: ProjectSetup.workflowCatalog.count)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            Group {
                switch section {
                case .allRuns, .failedRuns: runsTable
                case .usage: UsageView()
                case .quality: QualityView()
                case .skills: SkillTemplates()
                case .workflows: WorkflowTemplates()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.windowBackground)
        }
        .navigationTitle(section.title)
        .navigationSubtitle("Organizer · all projects")
        .task { load() }
        .onChange(of: model.engine.runs.count) { load() }
    }

    private func row(_ section: OrganizerSection, count: Int? = nil) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if let count { Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText) }
            }
        } icon: {
            Image(systemName: section.systemImage)
        }
        .tag(section)
    }

    private var projects: [Project] {
        var seen = Set<Int64>()
        return (model.openProjects + model.recentProjects).filter { $0.id.map { seen.insert($0).inserted } ?? false }
    }

    private func load() {
        rows = projects.flatMap { project in
            model.runs(in: [project]).map { run in
                OrganizerRunRow(run: run, projectName: project.name, checkRounds: checkRounds(run))
            }
        }
        .sorted { $0.run.startedAt > $1.run.startedAt }
    }

    private func checkRounds(_ run: Run) -> String {
        guard let id = run.id else { return "–" }
        let reports = ((try? model.database.runSteps(runId: id)) ?? []).compactMap { ProjectSignals.output(of: $0)?.checks }.flatMap(\.self)
        guard let round = reports.map(\.round).max() else { return "–" }
        let limit = run.snapshotWorkflow?.steps.first { $0.type == .check }?.maxRounds ?? ChecksConfig.defaultMaxRounds
        return "\(round) / \(limit)"
    }

    private var filteredRows: [OrganizerRunRow] {
        rows.filter { row in
            if section == .failedRuns, row.run.status != .failed { return false }
            if let projectFilter, row.run.projectId != projectFilter { return false }
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return true }
            return [row.run.displayTitle, row.projectName, row.run.workflow].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var runsTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                chip("All projects", isOn: projectFilter == nil) { projectFilter = nil }
                ForEach(projects) { project in
                    chip(project.name, isOn: projectFilter == project.id) { projectFilter = project.id }
                }
                Spacer()
                TextField("Filter runs, projects, workflows", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Table(filteredRows) {
                TableColumn("Status") { row in
                    HStack(spacing: 6) {
                        Circle().fill(model.statusColor(of: row.run)).frame(width: 7, height: 7)
                        Text(model.statusLabel(of: row.run)).foregroundStyle(model.statusColor(of: row.run))
                    }
                }
                .width(110)
                TableColumn("Run") { row in Text(row.run.displayTitle).fontWeight(.semibold) }
                TableColumn("Project") { row in Text(row.projectName).foregroundStyle(Theme.secondaryText) }.width(120)
                TableColumn("Workflow") { row in
                    Text([row.run.snapshotWorkflow?.name ?? row.run.workflow, row.run.workflowVersion.map { "v\($0)" }].compactMap(\.self).joined(separator: " "))
                        .foregroundStyle(Theme.secondaryText)
                }
                .width(140)
                TableColumn("Lines") { row in Text(row.run.linesChanged.map(String.init) ?? "–").font(.system(size: 12, design: .monospaced)) }.width(60)
                TableColumn("Check rounds") { row in Text(row.checkRounds).font(.system(size: 12, design: .monospaced)) }.width(90)
                TableColumn("Cost") { row in Text(row.run.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2)))).font(.system(size: 12, design: .monospaced)) }.width(70)
                TableColumn("Started") { row in Text(row.run.startedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.secondaryText) }.width(130)
            }
            .contextMenu(forSelectionType: OrganizerRunRow.ID.self) { ids in
                if let row = filteredRows.first(where: { ids.contains($0.id) }) {
                    Button("Open in Main Window") { open(row.run) }
                    Button("Open in New Window") { openWindow(id: WindowID.detail, value: DetailDestination.run(project: row.run.projectId, run: row.id)) }
                    Button("Copy Run ID") { model.copyToPasteboard(String(row.id)) }
                }
            } primaryAction: { ids in
                if let row = filteredRows.first(where: { ids.contains($0.id) }) { open(row.run) }
            }
            if filteredRows.isEmpty {
                Text(section == .failedRuns ? "No failed runs." : "No runs match.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(16)
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(isOn ? Theme.accent.opacity(0.22) : Color.white.opacity(0.06), in: .capsule)
                .overlay(Capsule().strokeBorder(isOn ? Theme.accent : Color.white.opacity(0.08)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func open(_ run: Run) {
        guard let id = run.id else { return }
        if model.project(withID: run.projectId) == nil {
            model.alert = AppAlert(title: "Project isn’t open", message: "Open the project to see this run.")
            return
        }
        model.openRunDetail(runID: id, in: run.projectId)
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

private struct SkillTemplates: View {
    @Environment(AppModel.self) private var model
    @State private var revision = 0

    var body: some View {
        List(ProjectSetup.skillCatalog) { skill in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Theme.link).frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(skill.description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if let project = model.currentProject {
                    let installed = revision >= 0 && SkillLibrary.installedSkills(in: project.url).contains(skill.name)
                    Button(installed ? "In \(project.name)" : "Add to \(project.name)") {
                        do {
                            _ = try skill.install(in: project.url)
                            revision += 1
                        } catch {
                            model.alert = AppAlert(title: "Couldn’t add \(skill.name)", message: error.localizedDescription)
                        }
                    }
                    .disabled(installed)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct WorkflowTemplates: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(ProjectSetup.workflowCatalog) { workflow in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(workflow.name) v\(workflow.version)").font(.system(size: 13, weight: .semibold))
                    Text(workflow.description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Text(workflow.steps.map { RunTimeline.title(ofStep: $0.id, in: workflow) }.joined(separator: " → "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.link)
                }
                Spacer()
                if let project = model.currentProject {
                    let installed = model.config(for: project).workflow(workflow.id) != nil
                    Button(installed ? "In \(project.name)" : "Add to \(project.name)") {
                        do {
                            try ProjectConfigLoader.write(workflow, repository: project.url)
                            model.reloadConfig(for: project)
                        } catch {
                            model.alert = AppAlert(title: "Couldn’t add \(workflow.name)", message: error.localizedDescription)
                        }
                    }
                    .disabled(installed)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
