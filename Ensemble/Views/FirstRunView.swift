import EnsembleCore
import EnsembleUI
import SwiftUI

struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    let report: EnvironmentReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    AppMark(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up Ensemble").font(.system(size: 22, weight: .bold))
                        Text("Ensemble drives the Claude Code CLI and git on this Mac. Everything below must pass before you open a project.")
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 0) {
                    ToolRow(name: "git", check: report.git) {
                        Text("Install the Xcode Command Line Tools with \(Text("xcode-select --install").font(Theme.monospaced)) in Terminal.")
                    }
                    Divider().overlay(Theme.hairline)
                    ToolRow(name: "Claude Code", check: report.claude) {
                        Text("Install the \(Text("claude").font(Theme.monospaced)) CLI, then check again.")
                    }
                    Divider().overlay(Theme.hairline)
                    ProviderRow(status: report.provider)
                    if let node = report.node {
                        Divider().overlay(Theme.hairline)
                        NodeRow(check: node, warning: report.nodeWarning)
                    }
                }
                .card(cornerRadius: 16)

                HStack {
                    Link("Claude Code setup guide", destination: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                        .foregroundStyle(Theme.link)
                    Spacer()
                    if model.isCheckingEnvironment {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Again") { Task { await model.checkEnvironment() } }
                        .buttonStyle(.primaryPill)
                        .disabled(model.isCheckingEnvironment)
                }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .background(Theme.windowBackground, in: .rect(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Tokens.hair2))
            .shadow(color: .black.opacity(0.55), radius: 40, y: 30)
            .padding(.vertical, 80)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Backdrop())
    }
}

private struct CheckRow<Detail: View>: View {
    let title: String
    let isOK: Bool
    let summary: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(isOK ? Theme.success : Theme.warning)
                .accessibilityLabel(isOK ? "Passed" : "Needs attention")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                detail
            }
        }
        .padding(16)
    }
}

private struct ToolRow<Hint: View>: View {
    let name: String
    let check: ToolCheck
    @ViewBuilder let hint: Hint

    var body: some View {
        switch check {
        case .found(let path, let version):
            CheckRow(title: name, isOK: true, summary: version) {
                Text(path.path.abbreviatingHome).font(Theme.monospaced).foregroundStyle(Theme.tertiaryText)
            }
        case .missing:
            CheckRow(title: name, isOK: false, summary: "Not found") {
                hint.foregroundStyle(Theme.secondaryText)
            }
        case .broken(let path, let message):
            CheckRow(title: name, isOK: false, summary: "Fails to run") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(path.path.abbreviatingHome).font(Theme.monospaced).foregroundStyle(Theme.tertiaryText)
                    Text(message).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                }
            }
        }
    }
}

private struct NodeRow: View {
    let check: ToolCheck
    let warning: String?

    var body: some View {
        CheckRow(title: EnvironmentReport.nodeCheckTitle, isOK: warning == nil, summary: summary) {
            VStack(alignment: .leading, spacing: 4) {
                if let path = check.path {
                    Text(path.path.abbreviatingHome).font(Theme.monospaced).foregroundStyle(Theme.tertiaryText)
                }
                Text(warning ?? "Specs open for review in Lavish.")
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if warning != nil {
                    Text("Optional: everything else works without it.").foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    private var summary: String {
        switch check {
        case .found(_, let version): warning == nil ? version : "\(version) · too old"
        case .missing: "Not found"
        case .broken: "Fails to run"
        }
    }
}

private struct ProviderRow: View {
    let status: ProviderStatus

    var body: some View {
        CheckRow(title: "Claude access", isOK: status.isOK, summary: status.summary) {
            ProviderChoice(status: status)
        }
    }
}

struct ProviderChoice: View {
    @Environment(AppModel.self) private var model
    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how agents connect to Claude. Agents only ever use the method you pick here.")
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(ProviderMode.allCases) { mode in
                    option(mode)
                }
            }
            switch status {
            case .notChosen:
                EmptyView()
            case .apiKey(let isStored):
                if isStored {
                    HStack {
                        Label("Key stored in your Keychain", systemImage: "key.fill").foregroundStyle(Theme.successText)
                        Spacer()
                        Button("Remove Key", role: .destructive) { Task { await model.removeAPIKey() } }
                            .buttonStyle(.pill)
                    }
                } else {
                    APIKeyField()
                }
            case .claudeSignIn(let account, let isSignedIn):
                if isSignedIn {
                    Label(account.map { "Signed in as \($0)" } ?? "Signed in", systemImage: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(Theme.successText)
                } else {
                    Text("Run \(Text("claude auth login").font(Theme.monospaced)) in Terminal, then check again.")
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func option(_ mode: ProviderMode) -> some View {
        let isSelected = status.mode == mode
        return Button {
            Task { await model.chooseProvider(mode) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                    Text(mode.title).font(.system(size: 13.5, weight: .semibold))
                }
                Text(.init(mode.billing))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isSelected ? Theme.accent.opacity(0.12) : Theme.fill, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Use \(mode.title)")
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct APIKeyField: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    var body: some View {
        HStack(spacing: 8) {
            SecureField("API key", text: $key, prompt: Text("sk-ant-…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button("Save to Keychain", action: save)
                .buttonStyle(.pill)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        let value = key
        key = ""
        Task { await model.saveAPIKey(value) }
    }
}

extension ProviderStatus {
    var summary: String {
        switch self {
        case .notChosen: "Choose one"
        case .apiKey(let isStored): isStored ? "API key" : "API key needed"
        case .claudeSignIn(_, let isSignedIn): isSignedIn ? "Claude sign-in" : "Not signed in"
        }
    }
}
