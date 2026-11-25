import SaturnUI
import SwiftUI

struct CloneRepositorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var remote = ""
    @State private var parent = CloneRepositorySheet.defaultParent
    @State private var folderName = ""
    @State private var hasEditedFolderName = false
    @State private var isChoosingParent = false
    @State private var isCloning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone Repository").font(.system(size: 20, weight: .bold))
                Text("Clone a git repository and open it as a project.").foregroundStyle(Theme.secondaryText)
            }

            Form {
                TextField("Repository URL", text: $remote, prompt: Text("https://github.com/owner/repo.git"))
                    .onChange(of: remote) {
                        if !hasEditedFolderName { folderName = Self.folderName(for: remote) }
                    }
                LabeledContent("Location") {
                    HStack {
                        Text(parent.path.abbreviatingHome).font(Theme.monospaced).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { isChoosingParent = true }
                    }
                }
                TextField("Folder name", text: Binding(get: { folderName }, set: { folderName = $0; hasEditedFolderName = true }))
            }
            .formStyle(.grouped)
            .disabled(isCloning)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isCloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button("Clone") { Task { await clone() } }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone)
            }
        }
        .padding(26)
        .frame(width: 560)
        .fileImporter(isPresented: $isChoosingParent, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { parent = url }
        }
    }

    private var canClone: Bool {
        !isCloning && !remote.trimmingCharacters(in: .whitespaces).isEmpty && !folderName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clone() async {
        isCloning = true
        errorMessage = nil
        defer { isCloning = false }
        do {
            try await model.clone(remote.trimmingCharacters(in: .whitespaces), into: parent, folderName: folderName.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func folderName(for remote: String) -> String {
        let last = remote.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "/" || $0 == ":" })
            .last
            .map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    static var defaultParent: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Code", "code", "Developer", "Projects"]
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? home
    }
}
