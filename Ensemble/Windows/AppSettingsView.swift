import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

enum NotificationPreferences {
    static func key(_ kind: ChatRequestKind) -> String {
        "notify.\(kind.rawValue)"
    }

    static func isEnabled(_ kind: ChatRequestKind) -> Bool {
        UserDefaults.standard.object(forKey: key(kind)) as? Bool ?? true
    }

    static func key(_ event: ChatNotificationEvent) -> String {
        "notify.chat.\(event.rawValue)"
    }

    static func isEnabled(_ event: ChatNotificationEvent) -> Bool {
        UserDefaults.standard.object(forKey: key(event)) as? Bool ?? true
    }
}

struct AppSettingsView: View {
    static let tabKey = "settings.tab"
    let updater: Updater
    @AppStorage(AppSettingsView.tabKey) private var tab = "accounts"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Accounts", systemImage: "person.crop.circle", value: "accounts") { AccountsSettings() }
            Tab("Engines", systemImage: "terminal", value: "engines") { EnginesSettings() }
            Tab("Key Bindings", systemImage: "keyboard", value: "keys") {
                KeyBindingsEditor().padding(20)
            }
            Tab("Notifications", systemImage: "bell", value: "notifications") { NotificationSettings() }
            Tab("Locations", systemImage: "folder", value: "locations") { LocationSettings() }
            Tab("Updates", systemImage: "arrow.clockwise", value: "updates") { UpdateSettings(updater: updater) }
            Tab("Editor Font", systemImage: "textformat", value: "font") { EditorFontSettings() }
        }
        .frame(width: 720, height: 560)
    }
}

private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
                Text("These settings apply to every project. Project settings (skills, checks, budgets, docs) live in each project’s Settings tab.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccountsSettings: View {
    var body: some View {
        SettingsPane {
            ClaudeAccessSettings()
        }
    }
}

private struct EnginesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPane {
            ToolsSettings()
            HStack {
                Button("Check Again") { Task { await model.checkEnvironment() } }
                    .disabled(model.isCheckingEnvironment)
                if model.isCheckingEnvironment { ProgressView().controlSize(.small) }
            }
            Text("More engines (Codex, Gemini CLI) arrive after the MVP.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct NotificationSettings: View {
    @State private var revision = 0

    var body: some View {
        SettingsPane {
            Text("Notify me about").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChatRequestKind.allCases, id: \.self) { kind in
                    Toggle(RequestNotifier.kindTitle(kind), isOn: Binding(
                        get: { _ = revision; return NotificationPreferences.isEnabled(kind) },
                        set: {
                            UserDefaults.standard.set($0, forKey: NotificationPreferences.key(kind))
                            revision += 1
                        }
                    ))
                }
            }
            Text("Lead chat").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChatNotificationEvent.allCases, id: \.self) { event in
                    Toggle(RequestNotifier.eventTitle(event), isOn: Binding(
                        get: { _ = revision; return NotificationPreferences.isEnabled(event) },
                        set: {
                            UserDefaults.standard.set($0, forKey: NotificationPreferences.key(event))
                            revision += 1
                        }
                    ))
                }
            }
            Button("Open System Notification Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

private struct LocationSettings: View {
    var body: some View {
        SettingsPane {
            location("Ensemble data", detail: "Database, transcripts, attachments and run evidence", url: AppPaths.standard.root)
            location("Debug logs", detail: "Traces of runs and chats, kept for a week", url: AppPaths.standard.debugLogsDirectory)
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktrees").font(.system(size: 12.5, weight: .semibold))
                Text("Each project keeps agent worktrees in .crew/ next to its code. Change the setup script and ports in a project’s Settings › Workspaces.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func location(_ title: String, detail: String, url: URL) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                Text(url.path.abbreviatingHome).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
            }
            Spacer()
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

private struct UpdateSettings: View {
    let updater: Updater
    @State private var automatic = false

    var body: some View {
        SettingsPane {
            if updater.isConfigured {
                Toggle("Check for updates automatically", isOn: Binding(get: { automatic }, set: {
                    automatic = $0
                    updater.automaticallyChecks = $0
                }))
                Text(updater.lastChecked.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not checked yet")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                Button("Check Now") { updater.checkForUpdates() }
            } else {
                Text("Updates aren’t configured in this build.").foregroundStyle(Theme.secondaryText)
            }
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
        }
        .onAppear { automatic = updater.isConfigured && updater.automaticallyChecks }
    }
}

private struct EditorFontSettings: View {
    @AppStorage(CodeStyle.fontSizeKey) private var size = CodeStyle.defaultFontSize

    var body: some View {
        SettingsPane {
            HStack {
                Text("Code size")
                Slider(value: $size, in: 10...18, step: 0.5).frame(width: 220)
                Text("\(size.formatted(.number.precision(.fractionLength(1)))) pt").font(.system(size: 12, design: .monospaced))
                Button("Default") { size = CodeStyle.defaultFontSize }.disabled(size == CodeStyle.defaultFontSize)
            }
            Text("def create_refund(order, amount):\n    return gateway.refund(order.payment_id, amount)")
                .font(.system(size: size, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CodeStyle.background, in: .rect(cornerRadius: 10))
            Text("Used by the source editor, file tabs and code blocks in transcripts.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
        }
    }
}
