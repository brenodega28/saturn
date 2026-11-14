import EnsembleCore
import EnsembleUI
import SwiftUI

struct SidebarAlertCard: View {
    @Environment(AppModel.self) private var model
    let alert: SystemAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                Text(alert.title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Tokens.stuck)
            Text(alert.message).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).fixedSize(horizontal: false, vertical: true)
            Button(AlertCopy.action(alert)) { model.resolve(alert) }
                .buttonStyle(SecondaryPillStyle())
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.stuckBackground, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.stuckLine))
        .accessibilityElement(children: .contain)
    }
}

struct ChatAlertBanner: View {
    @Environment(AppModel.self) private var model
    let alert: SystemAlert

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.stuck)
            Text(AlertCopy.banner(alert)).foregroundStyle(Tokens.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(AlertCopy.action(alert)) { model.resolve(alert) }.buttonStyle(.plain).foregroundStyle(Tokens.link)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Tokens.stuckBackground, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.stuckLine))
    }
}

enum AlertCopy {
    static func action(_ alert: SystemAlert) -> String {
        switch alert {
        case .claudeMissing, .claudeBroken: "Fix in Settings"
        case .rateLimited: "Details"
        case .hostDisconnected: "Reconnect"
        }
    }

    static func banner(_ alert: SystemAlert) -> String {
        switch alert {
        case .claudeMissing: "The Lead can’t reply: the Claude CLI isn’t installed."
        case .claudeBroken(let detail): "The Lead can’t reply: \(detail)"
        case .rateLimited: "\(alert.message) You can keep writing; messages send when it lifts."
        case .hostDisconnected(_, let host, _, _): "\(host) is disconnected. This chat is paused until it reconnects."
        }
    }
}

struct MenuBarStatus: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = model.chatSummaries().open.filter(\.stage.needsAttention)
        if waiting.isEmpty {
            Text("Nothing needs you")
        } else {
            Section("\(waiting.count) chat\(waiting.count == 1 ? "" : "s") need\(waiting.count == 1 ? "s" : "") you") {
                ForEach(waiting) { summary in
                    Button("\(summary.chat.title) · \(summary.stage.title)") {
                        NSApp.activate()
                        model.openChat(summary.chat)
                    }
                }
            }
        }
        Divider()
        Button("Open Ensemble") { NSApp.activate() }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.attentionCount(model.chatSummaries().open)
        HStack(spacing: 3) {
            Image(systemName: "person.2.wave.2")
            if count > 0 { Text("\(count)") }
        }
        .accessibilityLabel(count > 0 ? "\(count) chats need you" : "Ensemble")
    }
}
