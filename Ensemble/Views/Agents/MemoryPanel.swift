import EnsembleCore
import EnsembleUI
import SwiftUI

struct AgentSidePanel: View {
    let session: AgentSession
    let project: Project

    var body: some View {
        VStack(spacing: 12) {
            WorkspacePanel(session: session)
            if session.agent.isPinned {
                MemoryPanel(session: session, project: project)
            }
        }
    }
}

struct MemoryPanel: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let project: Project
    @State private var text = ""
    @State private var isEditing = false
    @State private var isConfirmingClear = false

    private var memory: AgentMemory {
        AgentMemory(repository: project.url, agentName: session.agent.name)
    }

    var body: some View {
        let notes = AgentMemory.notes(in: text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Memory").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isUpdatingMemory(session) {
                    ProgressView().controlSize(.mini)
                    Text("updating").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                } else {
                    Text("kept between runs").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)

            if text.isEmpty {
                Text("No notes yet. When a run this agent takes part in ends, it writes down what it learned.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if notes.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 10, style: .continuous))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                            noteRow(note, index: index)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(notes.count) note\(notes.count == 1 ? "" : "s") · \(AgentMemory.estimatedTokens(in: text).formatted()) tokens")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)

            HStack(spacing: 8) {
                Button { isEditing = true } label: {
                    Text("Edit memory").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(.secondary, height: 28))
                .help("Edit \(memory.url.lastPathComponent) in place")
                Button { isConfirmingClear = true } label: {
                    Text("Clear all").foregroundStyle(Color(hex: 0xFF8A80)).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(.secondary, height: 28))
                .disabled(text.isEmpty)
                .help("Delete every note this agent kept")
            }
        }
        .padding(14)
        .background(Theme.memory.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.memory.opacity(0.22)))
        .task(id: refreshKey) { reload() }
        .sheet(isPresented: $isEditing, onDismiss: reload) {
            MemoryEditorSheet(agentName: model.displayName(of: session.agent, in: project), file: memory.url, initialText: text) { edited in
                model.saveMemory(edited, for: session)
            }
        }
        .confirmationDialog("Clear \(model.displayName(of: session.agent, in: project))’s memory?", isPresented: $isConfirmingClear) {
            Button("Clear Memory", role: .destructive) {
                model.clearMemory(for: session)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every note in \(memory.url.lastPathComponent) is deleted. The agent starts its next run without them.")
        }
    }

    private var refreshKey: String {
        "\(session.id)-\(session.agent.status.rawValue)-\(session.transcript.entries.count)-\(model.isUpdatingMemory(session))"
    }

    private func reload() {
        text = memory.read().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func noteRow(_ note: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(note)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.forgetMemoryNote(at: index, for: session)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Forget this note")
            .accessibilityLabel("Forget this note")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agentName: String
    let file: URL
    let initialText: String
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agentName)’s memory").font(.system(size: 15, weight: .semibold))
                Text(file.path.abbreviatingHome)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
            Text("One note per “- ” line. Keep it under \(AgentMemory.maximumLines) lines; it is loaded into every turn.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Memory notes")
            HStack {
                Text("\(AgentMemory.notes(in: text).count) notes · \(AgentMemory.estimatedTokens(in: text).formatted()) tokens")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .buttonStyle(.primaryPill)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save the memory file")
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 520)
        .onAppear { text = initialText }
    }
}

struct MemoryBadge: View {
    let project: Project
    let agent: Agent

    var body: some View {
        let count = AgentMemory(repository: project.url, agentName: agent.name).noteCount
        HStack(spacing: 5) {
            Image(systemName: "brain").font(.system(size: 10.5, weight: .semibold))
            Text(count == 0 ? "Memory · empty" : "Memory · \(count) note\(count == 1 ? "" : "s")")
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .foregroundStyle(Theme.memory)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.memory.opacity(0.16), in: .rect(cornerRadius: 6, style: .continuous))
        .help("Pinned agents keep notes between runs in .ensemble/memory/")
        .accessibilityElement(children: .combine)
    }
}
