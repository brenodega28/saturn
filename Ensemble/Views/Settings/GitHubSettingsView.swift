import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct GitHubSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        SettingsPage("GitHub", subtitle: "Turn labelled GitHub issues into tasks. Ensemble checks for new issues on a timer, comments when a run starts and ends, and sets ensemble:running, ensemble:done or ensemble:failed.") {
            GitHubAccountCard()
            GitHubRepositoryCard(project: project)
            GitHubMappingsCard(project: project)
            GitHubPollingCard(project: project)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}

private struct GitHubAccountCard: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        let gitHub = model.gitHub
        SettingsCard("Account") {
            if gitHub.isSignedIn {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gitHub.user.map { "Signed in as \($0.login)" } ?? "Signed in")
                            .font(.system(size: 13, weight: .medium))
                        if let name = gitHub.user?.name {
                            Text(name).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer()
                    Button("Sign Out") { gitHub.signOut() }
                        .buttonStyle(.pill)
                        .help("Forget the GitHub token stored in the Keychain")
                }
            } else if let code = gitHub.deviceCode {
                deviceCodeView(code)
            } else {
                if gitHub.isDeviceFlowAvailable {
                    HStack {
                        Text("Sign in through github.com. No token to copy.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button("Sign In with GitHub") { gitHub.beginDeviceFlow() }
                            .buttonStyle(.primaryPill)
                            .disabled(gitHub.isSigningIn)
                            .help("Get a one-time code and confirm it on github.com")
                    }
                    Divider()
                }
                tokenEntry
            }
            if let error = gitHub.signInError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.warning).textSelection(.enabled)
            }
        }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.gitHub.isDeviceFlowAvailable ? "Or paste a personal access token" : "Paste a personal access token with the repo scope (classic), or a fine-grained token with Issues read and write.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("ghp_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Personal access token")
                    .onSubmit(useToken)
                Button("Use Token", action: useToken)
                    .buttonStyle(.pill)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || model.gitHub.isSigningIn)
                    .help("Check the token with GitHub and store it in the Keychain")
            }
        }
    }

    private func useToken() {
        let value = token
        Task {
            await model.gitHub.useToken(value)
            if model.gitHub.isSignedIn { token = "" }
        }
    }

    private func deviceCodeView(_ code: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter this code on GitHub").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 12) {
                Text(code.userCode)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy code")
                .help("Copy the code")
            }
            HStack(spacing: 10) {
                Button("Open GitHub") { NSWorkspace.shared.open(code.verificationURI) }
                    .buttonStyle(.primaryPill)
                    .help(code.verificationURI.absoluteString)
                ProgressView().controlSize(.small)
                Text("Waiting for you to authorize…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Cancel") { model.gitHub.cancelDeviceFlow() }
                    .buttonStyle(.pill)
                    .help("Stop waiting for GitHub")
            }
        }
    }
}

private struct GitHubRepositoryCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var draft = ""
    @State private var origin: String?

    var body: some View {
        SettingsCard("Repository") {
            HStack {
                TextField("owner/repo", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .accessibilityLabel("Repository")
                    .onSubmit(save)
                if !model.gitHub.repositories.isEmpty {
                    Menu("Choose") {
                        ForEach(model.gitHub.repositories) { repository in
                            Button(repository.fullName) {
                                draft = repository.fullName
                                save()
                            }
                        }
                    }
                    .fixedSize()
                    .help("Pick one of your repositories")
                }
                Button("Save", action: save)
                    .buttonStyle(.pill)
                    .disabled(normalized == (project.settings.githubRepository ?? ""))
                    .help("Use this repository for issues")
            }
            if let origin, origin != project.settings.githubRepository {
                Button("Use \(origin) from the origin remote") {
                    draft = origin
                    save()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .task(id: project.id) {
            draft = project.settings.githubRepository ?? ""
            origin = await model.originRepository(for: project)
            if project.settings.githubRepository == nil, let origin {
                draft = origin
                save()
            }
            await model.gitHub.loadRepositories()
        }
    }

    private var normalized: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        var settings = project.settings
        settings.githubRepository = normalized.isEmpty ? nil : normalized
        model.updateSettings(settings, for: project)
    }
}

private struct GitHubMappingsCard: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let workflows = model.workflows(for: project)
        let mappings = project.settings.githubMappings
        SettingsCard("Labels → workflows") {
            Text("Open issues with a mapped label become tasks. Auto-start runs the workflow straight away; otherwise the task waits in Incoming for you to accept.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if workflows.isEmpty {
                Text("This project has no workflows yet. Add the defaults in Settings › General.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
            ForEach(Array(mappings.enumerated()), id: \.offset) { index, mapping in
                MappingRow(mapping: mapping, workflows: workflows) { updated in
                    update { $0[index] = updated }
                } remove: {
                    update { $0.remove(at: index) }
                }
            }
            Button {
                let label = suggestedLabel(workflows: workflows, taken: Set(mappings.map(\.label)))
                update { $0.append(GitHubMapping(label: label, workflow: workflows.first?.id ?? "")) }
            } label: {
                Label("Add Mapping", systemImage: "plus")
            }
            .buttonStyle(.pill)
            .disabled(workflows.isEmpty)
            .help("Map another label to a workflow")
        }
    }

    private func suggestedLabel(workflows: [WorkflowDefinition], taken: Set<String>) -> String {
        let triggerLabels = workflows.filter { $0.trigger.sources.contains(.github) }.flatMap(\.trigger.labels)
        return (triggerLabels + ["agent-ready"]).first { !taken.contains($0) } ?? ""
    }

    private func update(_ change: (inout [GitHubMapping]) -> Void) {
        var settings = project.settings
        change(&settings.githubMappings)
        model.updateSettings(settings, for: project)
    }
}

private struct MappingRow: View {
    let mapping: GitHubMapping
    let workflows: [WorkflowDefinition]
    let save: (GitHubMapping) -> Void
    let remove: () -> Void
    @State private var label = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("label", text: $label)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 160)
                .accessibilityLabel("Issue label")
                .onChange(of: label) { commitLabel() }
            Image(systemName: "arrow.right").foregroundStyle(Theme.tertiaryText).accessibilityHidden(true)
            Picker("Workflow", selection: Binding(
                get: { mapping.workflow },
                set: { workflow in
                    var updated = mapping
                    updated.workflow = workflow
                    save(updated)
                }
            )) {
                if !workflows.contains(where: { $0.id == mapping.workflow }) {
                    Text(mapping.workflow.isEmpty ? "Choose…" : "\(mapping.workflow) (missing)").tag(mapping.workflow)
                }
                ForEach(workflows, id: \.id) { workflow in
                    Text(workflow.displayName).tag(workflow.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("The workflow issues with this label run")
            Toggle("Auto-start", isOn: Binding(
                get: { mapping.autoStart },
                set: { autoStart in
                    var updated = mapping
                    updated.autoStart = autoStart
                    save(updated)
                }
            ))
            .toggleStyle(.checkbox)
            .help("Start the workflow as soon as the issue is imported")
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove mapping for \(mapping.label)")
            .help("Remove this mapping")
        }
        .onAppear { label = mapping.label }
    }

    private func commitLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed != mapping.label else { return }
        var updated = mapping
        updated.label = trimmed
        save(updated)
    }
}

private struct GitHubPollingCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var result: String?
    @State private var isChecking = false

    private static let intervals = [1, 2, 5, 10, 15, 30, 60]

    var body: some View {
        let projectID = project.id ?? -1
        let poller = model.gitHub.poller
        SettingsCard("Checking for issues") {
            HStack(spacing: 12) {
                Picker("Check every", selection: Binding(
                    get: { project.settings.githubPollMinutes },
                    set: { minutes in
                        var settings = project.settings
                        settings.githubPollMinutes = minutes
                        model.updateSettings(settings, for: project)
                    }
                )) {
                    if !Self.intervals.contains(project.settings.githubPollMinutes) {
                        Text("\(project.settings.githubPollMinutes) minutes").tag(project.settings.githubPollMinutes)
                    }
                    ForEach(Self.intervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                .frame(maxWidth: 240)
                .help("How often Ensemble asks GitHub for new labelled issues")
                Spacer()
                Button(isChecking ? "Checking…" : "Check Now") {
                    Task {
                        isChecking = true
                        result = await model.checkGitHubNow(for: project)
                        isChecking = false
                    }
                }
                .buttonStyle(.primaryPill)
                .disabled(isChecking || !model.gitHub.isSignedIn || !GitHubPoller.isConfigured(project))
                .help("Look for new labelled issues now")
            }
            VStack(alignment: .leading, spacing: 4) {
                if let result {
                    Text(result).foregroundStyle(Theme.secondaryText)
                }
                if let last = poller.lastPolledAt[projectID] {
                    Text("Last checked \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(Theme.secondaryText)
                }
                if let backoff = poller.backoffUntil, backoff > .now {
                    Text("Rate limited until \(backoff.formatted(date: .omitted, time: .shortened))").foregroundStyle(Theme.warning)
                }
                if let error = poller.lastErrors[projectID] {
                    Text(error).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
                if let error = model.gitHub.writeBack.lastError {
                    Text(error).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
        }
    }
}
