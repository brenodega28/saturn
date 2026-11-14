import EnsembleCore
import EnsembleUI
import SwiftUI

struct LeadView: View {
    let project: Project

    var body: some View {
        ChatColumn(project: project)
    }
}

struct RequestCloseMenu: View {
    @Environment(AppModel.self) private var model
    let request: Chat
    let project: Project

    var body: some View {
        Button("Copy Link") { model.copyLink(to: request) }
        if !request.isClosed {
            Divider()
            let hasActiveRun = model.requestHasActiveRun(request)
            ForEach(RequestCloseReason.allCases, id: \.self) { reason in
                Button("Close as \(reason.title)") {
                    Task { await model.closeRequest(request, as: reason, in: project) }
                }
                .disabled(hasActiveRun)
            }
            if hasActiveRun {
                Divider()
                Text(RequestCloseReason.blockedHelp)
            }
        }
    }
}

struct CloseReasonBadge: View {
    let reason: RequestCloseReason

    var body: some View {
        Chip(text: reason.title, foreground: reason.color, background: reason.color.opacity(0.14))
    }
}

extension RequestCloseReason {
    static let blockedHelp = "Finish or cancel the run before closing this request."

    var color: Color {
        switch self {
        case .done: Theme.successText
        case .dropped: Theme.neutral
        }
    }
}

struct NewRequestHeldSends: View {
    @Environment(AppModel.self) private var model
    let held: [HeldSend]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(held) { send in
                    RequestBubble(held: send, onCancel: model.cancelHeldSend)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 16, trailing: 28))
        }
        .defaultScrollAnchor(.bottom)
        .followsBottom(of: held.map(\.id), jumpingOn: held.count, releasingOn: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NewRequestIntro: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let config = model.config(for: project)
        Group {
            if config.workflows.isEmpty {
                EmptyState("No workflows yet", message: "The lead starts a workflow from .ensemble/workflows/. Add the defaults to get Feature delivery and Small task.") {
                    Button("Add Default Workflows") { model.installDefaultConfig(in: project) }
                        .buttonStyle(.primaryPill)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("What should we build?")
                        .font(.system(size: 30, weight: .heavy).width(.expanded))
                        .foregroundStyle(Tokens.text)
                    Text("Describe it in your own words. The Lead writes a spec for you to approve, then starts the workers.")
                        .font(.system(size: 15))
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(NewChatStarter.allCases) { starter in
                            Button { model.composerPrefill = starter.prompt } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(starter.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Tokens.text)
                                    Text(starter.detail).font(.system(size: 12.5)).foregroundStyle(Tokens.text2).fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Tokens.raised, in: .rect(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.hair2))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: Tokens.Size.transcript)
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum NewChatStarter: String, CaseIterable, Identifiable {
    case bug
    case feature
    case understand

    var id: Self { self }

    var title: String {
        switch self {
        case .bug: "Fix a bug"
        case .feature: "Build a feature"
        case .understand: "Understand the code"
        }
    }

    var detail: String {
        switch self {
        case .bug: "Say what goes wrong and how to see it."
        case .feature: "Describe what it should do and who it’s for."
        case .understand: "Ask how something works; nothing changes."
        }
    }

    var prompt: String {
        switch self {
        case .bug: "Fix a bug: "
        case .feature: "Build a feature: "
        case .understand: "Explain how "
        }
    }
}
