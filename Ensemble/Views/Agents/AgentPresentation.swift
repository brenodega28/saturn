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

struct RoleAppearance: Hashable {
    let palette: RolePalette
    let symbol: String
    let face: RobotFace.Kind

    static let claude = RoleAppearance(palette: .claude, symbol: "terminal", face: .cli)

    init(palette: RolePalette, symbol: String, face: RobotFace.Kind = .cli) {
        self.palette = palette
        self.symbol = symbol
        self.face = face
    }

    init(role: RoleDefinition?) {
        guard let role else {
            self = .claude
            return
        }
        self.palette = RolePalette(rawValue: role.color) ?? .neutral
        self.symbol = Self.symbol(for: role.icon)
        self.face = RobotFace.Kind(icon: role.icon)
    }

    static let iconChoices = ["terminal", "lead", "reviewer", "qa", "django", "react", "scrum", "sparkle"]
    static let colorChoices = RolePalette.allCases.map(\.rawValue)

    static func symbol(for icon: String) -> String {
        switch icon {
        case "terminal", "claude": "terminal"
        case "lead", "compass": "safari"
        case "reviewer", "review": "text.magnifyingglass"
        case "qa", "test": "checkmark.shield"
        case "django", "database", "backend": "cylinder.split.1x2"
        case "react", "frontend", "web": "macwindow"
        case "scrum", "team": "person.3"
        case let name where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil: name
        default: "sparkle"
        }
    }
}

struct AgentAvatar: View {
    var size: CGFloat = 44
    var appearance: RoleAppearance = .claude

    var isFailing = false

    var body: some View {
        RobotFace(kind: appearance.face, size: size, isFailing: isFailing)
    }
}

struct StatusLabel: View {
    let status: AgentStatus
    var isQueued = false
    var retryingAt: Date?
    var apiRetry: LiveRetry?

    init(status: AgentStatus, isQueued: Bool = false, session: LiveAgentSession? = nil) {
        self.status = status
        self.isQueued = isQueued
        self.retryingAt = session?.retryingAt
        self.apiRetry = session?.isRunning == true ? session?.apiRetry : nil
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
    }

    private var text: String {
        if let retryingAt { return "Retrying at \(retryingAt.formatted(date: .omitted, time: .shortened))" }
        if let apiRetry { return "Retrying \(apiRetry.attempt) of \(apiRetry.maxRetries)" }
        return isQueued ? "Queued" : status.label
    }

    private var color: Color {
        if retryingAt != nil || apiRetry != nil { return Theme.warning }
        return isQueued ? Theme.neutral : status.color
    }
}

extension String {
    var modelTitle: String {
        AgentModel(rawValue: self)?.title ?? self
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
