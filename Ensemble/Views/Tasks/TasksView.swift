import EnsembleCore
import EnsembleUI
import SwiftUI

struct TasksView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var board = TaskBoard()
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TaskSourcesBar(project: project)
            if let loadError {
                Text(loadError).font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 198), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(TaskColumn.allCases) { column in
                        TaskColumnView(column: column, cards: board.cards(in: column), project: project)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .task(id: project.id) { await observeBoard() }
    }

    private func observeBoard() async {
        guard let projectID = project.id else { return }
        do {
            for try await snapshot in model.database.observeTaskBoard(projectId: projectID) {
                board = snapshot
                loadError = nil
            }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension TaskColumn {
    var color: Color {
        switch self {
        case .incoming: Color(hex: 0x7DB6FF)
        case .running: Theme.success
        case .waitingOnYou: Theme.warning
        case .done: Theme.neutral
        case .failed: Theme.danger
        }
    }
}

private struct TaskColumnView: View {
    let column: TaskColumn
    let cards: [TaskCard]
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(column.color, size: 8)
                Text(column.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(cards.count)").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if cards.isEmpty {
                Text("Nothing here")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(cards) { card in
                    TaskCardView(card: card, column: column, project: project)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
        .background(Color.white.opacity(0.03), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(column.title)
    }
}

private struct TaskSourcesBar: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("projectSettings.section") private var settingsSection: SettingsSection = .general
    let project: Project
    @State private var checkResult: String?
    @State private var isChecking = false

    var body: some View {
        let labels = project.settings.githubMappings.map(\.label).filter { !$0.isEmpty }
        HStack(spacing: 10) {
            Text("Sources").font(.system(size: 12.5, weight: .semibold))
            SourceChip(symbol: "bubble.left", text: Text("Lead chat"))
            if GitHubPoller.isConfigured(project), let repository = project.settings.githubRepository {
                SourceChip(symbol: "smallcircle.filled.circle", text: Text("GitHub \(repository) · \(Text(labels.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)))"))
                syncStatus
                Spacer(minLength: 8)
                Button(isChecking ? "Checking…" : "Check now") {
                    Task {
                        isChecking = true
                        checkResult = await model.checkGitHubNow(for: project)
                        isChecking = false
                    }
                }
                .buttonStyle(PillButtonStyle(height: 26))
                .disabled(isChecking || !model.gitHub.isSignedIn)
                .help("Look for new labelled issues on GitHub now")
            } else {
                Spacer(minLength: 8)
                Button("Connect GitHub Issues…") {
                    settingsSection = .github
                    model.setTab(.settings, for: project)
                }
                .buttonStyle(.link)
                .help("Pick a repository and map labels to workflows")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder
    private var syncStatus: some View {
        let projectID = project.id ?? -1
        if !model.gitHub.isSignedIn {
            Text("Not signed in").font(.system(size: 12)).foregroundStyle(Theme.warning)
        } else if let error = model.gitHub.poller.lastErrors[projectID] {
            Text(error).font(.system(size: 12)).foregroundStyle(Theme.warning).lineLimit(1).help(error)
        } else if let checkResult {
            Text(checkResult).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        } else if let last = model.gitHub.poller.lastPolledAt[projectID] {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Synced \(last.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

private struct SourceChip: View {
    let symbol: String
    let text: Text

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true)
            text.font(.system(size: 12)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.fillRaised, in: Capsule())
    }
}
