import EnsembleCore
import EnsembleUI
import SwiftUI

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(DaemonWorkspace.self) private var workspace
    let runID: Int64
    let project: Project
    @State private var snapshot: RunDetailSnapshot?
    @State private var hasLoaded = false
    @State private var section: RunDetailSection = .timeline

    static let wideLayoutWidth: CGFloat = 900

    var body: some View {
        let live = workspace.connection.run(id: runID)
        let hold = workspace.connection.holds[runID]
        let isActive = (live ?? snapshot?.run)?.isActive ?? true
        Group {
            if let snapshot {
                content(snapshot)
            } else if hasLoaded {
                EmptyState("This run is gone", message: "It may have been deleted. Go back to the project.") {
                    Button("Back") { workspace.closeRunDetail(in: project) }.buttonStyle(.pill)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: RefreshKey(runID: runID, isActive: isActive)) {
            reload()
            while isActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                reload()
            }
        }
        .onChange(of: live) { reload() }
        .onChange(of: hold) { reload() }
    }

    private func content(_ snapshot: RunDetailSnapshot) -> some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= Self.wideLayoutWidth
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RunDetailHeader(snapshot: snapshot, project: project, reload: reload)
                    if let hold = workspace.connection.holds[runID], hold.isChecksExhausted(in: snapshot.workflow) {
                        ChecksExhaustedCard(run: snapshot.run, project: project, rounds: snapshot.run.checkRounds(at: hold.stepId, in: project), reload: reload)
                    }
                    if isWide {
                        HStack(alignment: .top, spacing: 16) {
                            graphCard(snapshot)
                                .frame(width: min(420, proxy.size.width * 0.42))
                            sections(snapshot)
                        }
                    } else {
                        graphCard(snapshot)
                        sections(snapshot)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func graphCard(_ snapshot: RunDetailSnapshot) -> some View {
        if let graph = snapshot.graph {
            RunGraphCard(graph: graph, roles: workspace.config(for: project).roles, workflowName: snapshot.workflow?.displayName)
        } else {
            Text("The workflow this run started with couldn’t be read.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(cornerRadius: 16)
        }
    }

    private func sections(_ snapshot: RunDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CapsuleTabs(RunDetailSection.allCases, selection: $section, title: \.title)
                .fixedSize()
            switch section {
            case .timeline:
                RunTimelineView(snapshot: snapshot, project: project)
            case .agents:
                RunAgentsPanel(snapshot: snapshot, project: project)
            case .logs:
                RunLogsView(snapshot: snapshot, project: project)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func reload() {
        snapshot = workspace.runDetailSnapshot(runID: runID)
        hasLoaded = true
    }
}

private struct RefreshKey: Hashable {
    let runID: Int64
    let isActive: Bool
}
