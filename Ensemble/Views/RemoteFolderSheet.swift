import EnsembleCore
import EnsembleUI
import SwiftUI

struct RemoteFolderSheet: View {
    private enum Field: Hashable {
        case host
        case path
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("remoteFolder.lastHost") private var lastHost = ""

    @State private var hostInput = ""
    @State private var configHosts: [String] = []
    @State private var connection: (destination: String, info: RemoteHostInfo)?
    @State private var browser: RemoteFolderBrowser?
    @State private var isConnecting = false
    @State private var isOpening = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open SSH Folder").font(.system(size: 20, weight: .bold))
                Text("Open a git repository on another machine. Ensemble connects with your SSH keys and ~/.ssh/config.")
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            hostSection

            if let connection, let browser {
                HostSummary(destination: connection.destination, info: connection.info)
                FolderNavigator(browser: browser, focus: $focus, pathField: .path, onOpen: open)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(26)
        .frame(width: 600)
        .disabled(isOpening)
        .onAppear {
            configHosts = SSHConfigHosts.load()
            hostInput = lastHost
            focus = .host
        }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Host", text: $hostInput, prompt: Text("Alias from ~/.ssh/config or user@host:port"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focus, equals: .host)
                    .onSubmit { Task { await connect() } }
                    .onChange(of: hostInput) {
                        if connection.map({ $0.destination != (try? SSHDestination.normalize(hostInput)) }) ?? false {
                            connection = nil
                            browser = nil
                        }
                    }
                Button(connection == nil ? "Connect" : "Reconnect") { Task { await connect() } }
                    .buttonStyle(.pill)
                    .disabled(isConnecting || hostInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if connection == nil, !hostSuggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(hostSuggestions, id: \.self) { alias in
                        Button(alias) {
                            hostInput = alias
                            Task { await connect() }
                        }
                        .buttonStyle(.pill)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var hostSuggestions: [String] {
        let typed = hostInput.trimmingCharacters(in: .whitespaces)
        let matches = typed.isEmpty ? configHosts : configHosts.filter { $0.localizedCaseInsensitiveContains(typed) && $0 != typed }
        return Array(matches.prefix(12))
    }

    private var footer: some View {
        HStack {
            if isConnecting || isOpening {
                ProgressView().controlSize(.small)
                Text(isOpening ? "Opening…" : "Connecting…").foregroundStyle(Theme.secondaryText)
            } else if browser != nil {
                Text("Tab completes · ↑↓ choose · Return opens")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)
            Button("Open") { open() }
                .buttonStyle(.primaryPill)
                .disabled(browser == nil || isOpening)
        }
    }

    private func connect() async {
        let destination: String
        do {
            destination = try SSHDestination.normalize(hostInput)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        let host = model.remoteHost(destination)
        do {
            let info = try await host.probe()
            connection = (destination, info)
            browser = RemoteFolderBrowser(lister: host)
            lastHost = hostInput.trimmingCharacters(in: .whitespaces)
            focus = .path
        } catch {
            connection = nil
            browser = nil
            errorMessage = error.localizedDescription
        }
    }

    private func open() {
        guard let connection, let browser else { return }
        let path = browser.resolvedPath
        isOpening = true
        errorMessage = nil
        Task {
            defer { isOpening = false }
            do {
                try await model.openRemoteFolder(host: connection.destination, path: path)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct HostSummary: View {
    let destination: String
    let info: RemoteHostInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(Theme.link)
            Text(SSHDestination.displayName(destination)).font(.system(size: 12.5, weight: .semibold))
            Text(info.system).foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            tool("git", found: info.gitPath != nil)
            tool("claude", found: info.claudePath != nil)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.fillRaised, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func tool(_ name: String, found: Bool) -> some View {
        Label(name, systemImage: found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(found ? Theme.successText : Theme.warning)
            .help(found ? "\(name) is installed on the host" : "\(name) wasn’t found on the host’s PATH")
    }
}

private struct FolderNavigator<Field: Hashable>: View {
    @Bindable var browser: RemoteFolderBrowser
    var focus: FocusState<Field?>.Binding
    let pathField: Field
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.pill)
                    .help("Parent folder")
                TextField("Folder", text: $browser.input, prompt: Text("~/"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused(focus, equals: pathField)
                    .onKeyPress(.tab) { browser.completeHighlighted() ? .handled : .ignored }
                    .onKeyPress(.downArrow) {
                        browser.moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        browser.moveHighlight(by: -1)
                        return .handled
                    }
                    .onSubmit {
                        if let entry = browser.highlightedEntry {
                            browser.descend(into: entry)
                        } else {
                            onOpen()
                        }
                    }
                    .onAppear { focus.wrappedValue = pathField }
            }
            suggestions
            if let listing = browser.listing {
                Text(browser.completion.namesDirectoryExactly ? "Opens \(listing.path)" : "In \(listing.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var suggestions: some View {
        let entries = browser.suggestions
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        FolderRow(entry: entry, isHighlighted: index == browser.highlighted) {
                            browser.descend(into: entry)
                            focus.wrappedValue = pathField
                        }
                        .id(entry.id)
                    }
                }
                .padding(4)
            }
            .frame(height: 240)
            .background(Color.black.opacity(0.18), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.hair))
            .overlay { placeholder(isEmpty: entries.isEmpty) }
            .onChange(of: browser.highlighted) {
                if let entry = browser.highlightedEntry { proxy.scrollTo(entry.id) }
            }
        }
    }

    @ViewBuilder
    private func placeholder(isEmpty: Bool) -> some View {
        switch browser.status {
        case .loading where isEmpty:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Text(message).foregroundStyle(Theme.danger).multilineTextAlignment(.center).padding()
        case .loaded where isEmpty:
            Text(browser.completion.filter.isEmpty ? "No folders here" : "No folders match “\(browser.completion.filter)”")
                .foregroundStyle(Theme.tertiaryText)
        default:
            EmptyView()
        }
    }
}

private struct FolderRow: View {
    let entry: RemoteDirectory.Entry
    let isHighlighted: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(entry.isGitRepository ? Theme.link : Theme.secondaryText)
                    .frame(width: 18)
                Text(entry.name)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if entry.isGitRepository {
                    Text("git")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.link)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Theme.link.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(isHighlighted ? Theme.link.opacity(0.22) : isHovered ? Tokens.fill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(entry.isGitRepository ? "\(entry.name), git repository" : entry.name)
    }
}
