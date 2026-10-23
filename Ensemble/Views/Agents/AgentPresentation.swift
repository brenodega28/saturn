import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

extension AgentStatus {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs you"
        case .waiting: "Waiting"
        case .reviewing: "Reviewing"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .stopped: "Stopped"
        case .takenOver: "With you"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .working: Theme.success
        case .needsInput, .interrupted: Theme.warning
        case .reviewing, .takenOver: Theme.info
        case .paused: Theme.paused
        case .failed: Theme.danger
        case .idle, .waiting, .stopped: Theme.neutral
        }
    }
}

extension Agent {
    var tokensAndCost: String {
        "\(totalTokens.formatted(.number.notation(.compactName))) tokens · \(costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))"
    }
}

struct AgentAvatar: View {
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RolePalette.claude.gradient, in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
            .accessibilityHidden(true)
    }
}

struct StatusLabel: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status.color)
            Text(status.label)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(status.color)
    }
}

struct ExternalApp: Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String
    let url: URL

    var id: String { bundleIdentifier }

    static let editorCandidates = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Zed", "dev.zed.Zed"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("BBEdit", "com.barebones.bbedit"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    static let terminalCandidates = [
        ("Terminal", "com.apple.Terminal"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("WezTerm", "com.github.wez.wezterm"),
    ]

    static func installed(_ candidates: [(String, String)]) -> [ExternalApp] {
        candidates.compactMap { name, bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
                ExternalApp(name: name, bundleIdentifier: bundleIdentifier, url: $0)
            }
        }
    }

    func open(_ folder: URL) {
        NSWorkspace.shared.open([folder], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct OpenWithMenu: View {
    let title: String
    let systemImage: String
    let apps: [ExternalApp]
    let folder: URL
    @Binding var preferred: String

    var body: some View {
        let primary = apps.first { $0.bundleIdentifier == preferred } ?? apps.first
        Menu {
            ForEach(apps) { app in
                Button(app.name) {
                    preferred = app.bundleIdentifier
                    app.open(folder)
                }
            }
        } label: {
            Label(primary.map { "\(title) · \($0.name)" } ?? title, systemImage: systemImage)
        } primaryAction: {
            primary?.open(folder)
        }
        .disabled(apps.isEmpty)
    }
}
