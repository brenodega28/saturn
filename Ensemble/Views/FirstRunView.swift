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
                    ProviderRow(access: report.provider)
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
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
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

private struct ProviderRow: View {
    let access: ProviderAccess

    var body: some View {
        CheckRow(title: "Anthropic access", isOK: access.isOK, summary: access.summary) {
            if access.isOK {
                Text(access.detail).foregroundStyle(Theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in with \(Text("claude auth login").font(Theme.monospaced)) in Terminal, or paste an Anthropic API key. Keys are stored in your Keychain.")
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    APIKeyField()
                }
            }
        }
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

extension ProviderAccess {
    var summary: String {
        switch self {
        case .apiKey: "API key"
        case .claudeLogin: "Claude Code login"
        case .none: "Not set up"
        }
    }

    var detail: String {
        switch self {
        case .apiKey: "Using the API key stored in your Keychain."
        case .claudeLogin(let method): "Using your Claude Code sign-in\(method.map { " (\($0))" } ?? "")."
        case .none: "No API key and no Claude Code sign-in."
        }
    }
}
