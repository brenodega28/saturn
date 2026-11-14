import Foundation

extension AgentWorkflowDriver {
    nonisolated static let maxEvidenceBytes = 200 * 1024 * 1024
    nonisolated static let maxRemoteEvidenceBytes = 50 * 1024 * 1024

    func attachEvidence(_ draft: EvidenceDraft, runId: Int64, agent: Agent) async throws -> String {
        let project = try runtime.database.project(id: agent.projectId)
        if let project, let client = project.sshClient {
            return try await attachRemoteEvidence(draft, runId: runId, agent: agent, project: project, client: client)
        }
        let base = agent.worktreeURL ?? project?.url ?? FileManager.default.temporaryDirectory
        let source = draft.file.hasPrefix("/") ? URL(filePath: draft.file) : base.appending(path: draft.file)
        let resolved = realPath(of: source)
        let allowed = [agent.worktreeURL, project?.url, FileManager.default.temporaryDirectory, URL(filePath: "/tmp")]
            .compactMap(\.self)
            .map { realPath(of: $0) + "/" }
        guard allowed.contains(where: { resolved.hasPrefix($0) }) else {
            throw HandoffError.notAllowed("Evidence must be inside your worktree, the project or the temporary folder; \(draft.file) isn’t.")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        guard let size = attributes?[.size] as? Int, attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw HandoffError.notAllowed("There’s no file at \(draft.file).")
        }
        guard size <= Self.maxEvidenceBytes else {
            throw HandoffError.notAllowed("\(draft.file) is larger than 200 MB; attach a shorter recording or a trimmed log.")
        }
        let directory = runtime.paths.evidenceDirectory(runId: runId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(UUID().uuidString.prefix(8).lowercased())-\(URL(filePath: resolved).lastPathComponent)")
        try FileManager.default.copyItem(at: URL(filePath: resolved), to: target)
        try runtime.database.addEvidence(Evidence(
            runId: runId, agentId: agent.id, kind: draft.kind, title: draft.title, file: target.path, note: draft.note, createdAt: .now
        ))
        return "Attached “\(draft.title)” for the user to see in Changes."
    }

    private func attachRemoteEvidence(_ draft: EvidenceDraft, runId: Int64, agent: Agent, project: Project, client: SSHClient) async throws -> String {
        let base = agent.worktreeURL ?? project.url
        let resolved = SSHFileSystem.normalize(draft.file.hasPrefix("/") ? draft.file : base.path + "/" + draft.file)
        let allowed = [agent.worktreeURL?.path, project.path, "/tmp"].compactMap(\.self).map { SSHFileSystem.normalize($0) + "/" }
        guard allowed.contains(where: { resolved.hasPrefix($0) }) else {
            throw HandoffError.notAllowed("Evidence must be inside your worktree, the project or /tmp on the host; \(draft.file) isn’t.")
        }
        let size = try? await client.run(arguments: ["sh", "-c", #"[ -f "$1" ] && wc -c < "$1""#, "ensemble", resolved])
        guard let size, size.succeeded, let bytes = Int(size.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HandoffError.notAllowed("There’s no file at \(draft.file).")
        }
        guard bytes <= Self.maxRemoteEvidenceBytes else {
            throw HandoffError.notAllowed("\(draft.file) is larger than \(Self.maxRemoteEvidenceBytes / 1024 / 1024) MB, the limit for evidence from an SSH host; attach a shorter recording or a trimmed log.")
        }
        guard let data = try await SSHFileSystem(client: client).readData(URL(fileURLWithPath: resolved)) else {
            throw HandoffError.notAllowed("Ensemble couldn’t copy \(draft.file) from the host.")
        }
        let directory = runtime.paths.evidenceDirectory(runId: runId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(UUID().uuidString.prefix(8).lowercased())-\(URL(filePath: resolved).lastPathComponent)")
        try data.write(to: target)
        try runtime.database.addEvidence(Evidence(
            runId: runId, agentId: agent.id, kind: draft.kind, title: draft.title, file: target.path, note: draft.note, createdAt: .now
        ))
        return "Attached “\(draft.title)” for the user to see in Changes."
    }
}
