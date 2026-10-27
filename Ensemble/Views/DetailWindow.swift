import EnsembleCore
import EnsembleUI
import SwiftUI

struct DetailWindow: View {
    @Environment(AppModel.self) private var model
    let destination: DetailDestination?

    var body: some View {
        Group {
            if let destination, let project = model.project(withID: destination.projectID) {
                content(destination, project: project)
                    .padding(EdgeInsets(top: 10, leading: 22, bottom: 20, trailing: 22))
            } else {
                EmptyState("Nothing to show", message: "This project is closed or the item no longer exists.")
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Theme.windowBackground)
    }

    @ViewBuilder
    private func content(_ destination: DetailDestination, project: Project) -> some View {
        switch destination {
        case .run(_, let runID):
            RunDetailView(runID: runID, project: project)
        case .agent(_, let agentID):
            if let session = model.agentSessions(in: project).first(where: { $0.id == agentID }) {
                AgentSessionView(session: session, project: project)
            } else {
                EmptyState("Agent not found", message: "The agent was deleted.")
            }
        case .file(_, let path):
            DetailFileView(project: project, path: path)
        }
    }
}

private struct DetailFileView: View {
    let project: Project
    let path: String

    var body: some View {
        let document = CodeWorkspace.document(at: project.url.appending(path: path))
        VStack(alignment: .leading, spacing: 8) {
            Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
            ScrollView([.vertical, .horizontal]) {
                Text(Self.text(of: document))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    static func text(of document: CodeDocument) -> String {
        switch document {
        case .text(let lines): lines.joined(separator: "\n")
        case .binary: "This is a binary file."
        case .tooLarge(let bytes): "This file is too large to show (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        case .missing: "This file no longer exists."
        }
    }
}

extension DetailDestination {
    var projectID: Int64 {
        switch self {
        case .run(let project, _), .agent(let project, _), .file(let project, _): project
        }
    }

    var title: String {
        switch self {
        case .run: "Run"
        case .agent: "Agent"
        case .file(_, let path): (path as NSString).lastPathComponent
        }
    }
}
