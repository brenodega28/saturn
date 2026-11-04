import EnsembleCore
import EnsembleUI
import SwiftUI

enum LogScope: String, CaseIterable, Identifiable {
    case all
    case chat
    case needsYou

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .chat: "This chat"
        case .needsYou: "Needs you"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Nothing logged yet. Runs and agents report here as they work."
        case .chat: "Nothing from this chat’s runs or agents yet."
        case .needsYou: "Nothing needs you."
        }
    }
}

struct ChatLogScope: Equatable {
    var runs: Set<Int64> = []
    var agents: Set<Int64> = []

    func contains(_ entry: LogEntry) -> Bool {
        if let run = entry.runId, runs.contains(run) { return true }
        if let agent = entry.agentId, agents.contains(agent) { return true }
        return false
    }
}

extension AppModel {
    func chatLogScope() -> ChatLogScope {
        guard let project = currentProject, let request = selectedRequestID else { return ChatLogScope() }
        let runs = Set(((try? database.runs(taskId: request)) ?? []).compactMap(\.id))
        let agents = agentSessions(in: project).filter { session in
            session.agent.runId.map(runs.contains) == true || session.agent.taskId == request
        }
        return ChatLogScope(runs: runs, agents: Set(agents.map(\.id)))
    }

    func logEntries(_ scope: LogScope) -> [LogEntry] {
        let projects = Set(openProjects.compactMap(\.id))
        let entries = activityLog.entries(matching: LogFilter(), projectIds: projects)
        switch scope {
        case .all:
            return entries
        case .chat:
            let chat = chatLogScope()
            return entries.filter(chat.contains)
        case .needsYou:
            return entries.filter { $0.level == .warning }
        }
    }

    func open(_ entry: LogEntry) {
        guard let projectID = entry.projectId, let project = project(withID: projectID) else { return }
        mainWindow.spec = nil
        if let agentID = entry.agentId, let agent = agent(id: agentID) {
            openAgentSession(agent, in: project)
        } else if let runID = entry.runId {
            openRunDetail(runID: runID, in: projectID)
        }
    }
}

extension LogEntry.Level {
    var v4Color: Color {
        switch self {
        case .info: Color(hex: 0x4BD97B)
        case .debug: Color(hex: 0x7DB6FF)
        case .warning: Color(hex: 0xFFB340)
        case .error: Color(hex: 0xFF6B61)
        }
    }

    var rowTint: Color {
        switch self {
        case .error: Color(red: 1, green: 69 / 255, blue: 58 / 255).opacity(0.08)
        case .warning: Color(red: 1, green: 159 / 255, blue: 10 / 255).opacity(0.06)
        case .info, .debug: .clear
        }
    }

    var spokenName: String {
        switch self {
        case .info: "Info"
        case .debug: "Debug"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

struct LogColumn: View {
    @Environment(AppModel.self) private var model
    @AppStorage("v4.log.scope") private var scope: LogScope = .all

    var body: some View {
        let entries = model.logEntries(scope)
        let sources = sourceFills
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                Text(scope.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(V4.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            LogRow(entry: entry, fill: fill(for: entry, in: sources))
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .followsBottom(of: entries.last?.id)
                .id(scope)
                .accessibilityLabel("Raw log")
            }
        }
        .frame(width: 470)
        .frame(maxHeight: .infinity)
        .background(V4.logFill, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Log")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Log")
                .font(.system(size: 14, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 5) {
                Circle().fill(V4.green).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("live").font(.system(size: 11.5)).foregroundStyle(V4.greenText)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(LogScope.allCases) { option in
                    let isOn = option == scope
                    Button { scope = option } label: {
                        Text(option.title)
                            .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(isOn ? Color.white.opacity(0.16) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                            .contentShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter")
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
    }

    private var sourceFills: [Int64: LinearGradient] {
        var fills: [Int64: LinearGradient] = [:]
        for project in model.openProjects {
            for session in model.agentSessions(in: project) {
                fills[session.id] = RoleAppearance(role: model.role(for: session.agent, in: project)).palette.gradient
            }
        }
        return fills
    }

    private func fill(for entry: LogEntry, in sources: [Int64: LinearGradient]) -> LinearGradient {
        entry.agentId.flatMap { sources[$0] } ?? V4.railsGradient
    }
}

private struct LogRow: View {
    @Environment(AppModel.self) private var model
    let entry: LogEntry
    let fill: LinearGradient
    @State private var isHovered = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let isOpenable = entry.projectId != nil && (entry.agentId != nil || entry.runId != nil)
        let time = Self.time.string(from: entry.date)
        HStack(alignment: .top, spacing: 8) {
            Text(time)
                .foregroundStyle(V4.secondary)
                .frame(width: 62, alignment: .leading)
            Text(entry.level.rawValue)
                .fontWeight(.bold)
                .foregroundStyle(entry.level.v4Color)
                .frame(width: 14, alignment: .leading)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(fill).frame(width: 7, height: 7)
                Text(entry.source).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: 62, height: 14, alignment: .leading)
            .clipped()
            Text(entry.message)
                .foregroundStyle(Color.white.opacity(0.88))
                .lineSpacing(6.3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(V4.monospaced(11.5))
        .padding(.vertical, 3.15)
        .padding(.horizontal, 14)
        .background(isOpenable && isHovered ? Color.white.opacity(0.05) : entry.level.rowTint)
        .contentShape(.rect)
        .onTapGesture { if isOpenable { model.open(entry) } }
        .onHover { isHovered = $0 }
        .help(isOpenable ? (entry.agentId != nil ? "Open \(entry.source)’s session" : "Open the run") : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(time), \(entry.level.spokenName), \(entry.source): \(entry.message)")
        .accessibilityAddTraits(isOpenable ? .isButton : [])
        .accessibilityAction { if isOpenable { model.open(entry) } }
    }
}
