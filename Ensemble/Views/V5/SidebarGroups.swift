import EnsembleCore
import EnsembleUI
import SwiftUI

struct ProjectFilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: String

    var body: some View {
        let projects = model.allOpenProjects.map { (key: Self.key($0.workspace, $0.project), workspace: $0.workspace, project: $0.project) }
        HStack(spacing: 6) {
            Menu {
                Button("All projects") { filter = ProjectFilterKey.all }
                Divider()
                ForEach(projects, id: \.key) { key, workspace, project in
                    Button(workspace.isRemote ? "\(project.name) · \(workspace.displayName)" : project.name) { filter = key }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11, weight: .semibold))
                    Text(title(projects)).lineLimit(1)
                    Text("▾").font(.system(size: 9)).foregroundStyle(Tokens.text2)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text)
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10))
                .frame(height: 28)
                .overlay(Capsule().strokeBorder(Tokens.hair2))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Filter by project")
            .accessibilityValue(title(projects))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(projects, id: \.key) { key, workspace, project in
                        chip(key, workspace, project)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 2)
    }

    static func key(_ workspace: DaemonWorkspace, _ project: Project) -> String {
        ProjectFilterKey.make(daemon: workspace.id, projectID: project.id)
    }

    private func title(_ projects: [(key: String, workspace: DaemonWorkspace, project: Project)]) -> String {
        projects.first { $0.key == filter }?.project.name ?? "All projects"
    }

    private func chip(_ key: String, _ workspace: DaemonWorkspace, _ project: Project) -> some View {
        let isOn = filter == key
        let name = workspace.isRemote ? "\(project.name) on \(workspace.displayName)" : project.name
        return Button { filter = isOn ? ProjectFilterKey.all : key } label: {
            ProjectTile(project: project, size: 18)
                .frame(width: 28, height: 28)
                .background(isOn ? Tokens.selection : .clear, in: Circle())
                .overlay(Circle().strokeBorder(isOn ? Tokens.text2 : Tokens.hair))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Only \(name)")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

extension ChatGroup {
    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .inProgress: "In progress"
        case .notStarted: "Not started"
        case .finished: "Finished"
        }
    }

    var titleColor: Color { self == .needsYou ? Tokens.need : Tokens.text2 }

    var collapsedKey: String { "sidebar.group.\(rawValue)" }
}

struct GroupHeader: View {
    let title: String
    var color: Color = Tokens.text2
    let count: Int
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .heavy))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(title).foregroundStyle(color)
                Text("\(count)").font(Tokens.mono(12))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tokens.text2)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
    }
}

struct StatusGroup: View {
    let group: ChatGroup
    let summaries: [ChatSummary]
    let drafts: [DraftSummary]
    @AppStorage private var isCollapsed: Bool

    init(group: ChatGroup, summaries: [ChatSummary], drafts: [DraftSummary]) {
        self.group = group
        self.summaries = summaries
        self.drafts = drafts
        _isCollapsed = AppStorage(wrappedValue: false, group.collapsedKey, store: AppDefaults.store)
    }

    var body: some View {
        if !summaries.isEmpty || !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                GroupHeader(title: group.title, color: group.titleColor, count: summaries.count + drafts.count, isOpen: !isCollapsed) { isCollapsed.toggle() }
                if !isCollapsed {
                    ForEach(drafts) { draft in DraftRow(summary: draft).inWorkspace(draft.daemon) }
                    ForEach(summaries) { summary in ChatRow(summary: summary).inWorkspace(summary.daemon) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(group.title)
        }
    }
}

struct FinishedPanel: View {
    static let closedLimit = 24
    static let maxHeight: CGFloat = 250
    static let background = Color.adaptive(dark: 0x08080A, light: 0xEDEDF0)

    let finished: [ChatSummary]
    let closed: [ChatSummary]
    @AppStorage(ChatGroup.finished.collapsedKey, store: AppDefaults.store) private var isCollapsed = false
    @State private var showsClosed = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        if !finished.isEmpty || !closed.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                header
                if showsClosed {
                    scrolling { closedList }
                } else if !isCollapsed && !finished.isEmpty {
                    scrolling {
                        ForEach(finished) { summary in ChatRow(summary: summary).inWorkspace(summary.daemon) }
                    }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 2, trailing: 10))
            .background(Self.background)
            .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
            .padding(.horizontal, -10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(showsClosed ? "Closed" : "Finished")
            .onChange(of: closed.isEmpty) { _, isEmpty in if isEmpty { showsClosed = false } }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 0) {
            if showsClosed {
                Button { showsClosed = false } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.left").font(.system(size: 8, weight: .heavy))
                        Text("Closed")
                        Text("\(closed.count)").font(Tokens.mono(12))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Back to Finished")
                .accessibilityLabel("Back to Finished")
            } else {
                GroupHeader(title: ChatGroup.finished.title, count: finished.count, isOpen: !isCollapsed) { isCollapsed.toggle() }
            }
            Spacer()
            if !showsClosed && !closed.isEmpty {
                Button { showsClosed = true } label: {
                    Text("Closed \(closed.count) ›")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.text2)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(closed.count) closed chats")
            }
        }
    }

    @ViewBuilder
    private var closedList: some View {
        ForEach(closed.prefix(Self.closedLimit)) { summary in ClosedChatRow(summary: summary).inWorkspace(summary.daemon) }
        if closed.count > Self.closedLimit {
            Text("Older closed chats are in ⌘K search.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.text3)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) { content() }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, Self.maxHeight))
    }
}

struct StageGlyph: View {
    let stage: ChatStage
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 16, y: canvas.height / 16)
            let ring = Path(ellipseIn: CGRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
            if let fill { context.fill(ring, with: .color(fill)) }
            context.stroke(ring, with: .color(stage.color), style: StrokeStyle(lineWidth: 1.5, dash: isDashed ? [2.2, 2.2] : []))
            if let pie { context.fill(Self.pie(pie), with: .color(stage.color)) }
            if let mark { context.stroke(mark.path, with: .color(mark.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)) }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(stage.title)
    }

    private var fill: Color? {
        switch stage {
        case .stuck: Tokens.stuck
        case .finished, .done: Tokens.done
        default: nil
        }
    }

    private var isDashed: Bool { stage == .idle || stage == .dropped }

    private var pie: Double? {
        switch stage {
        case .building: 0.5
        case .inReview: 0.75
        default: nil
        }
    }

    private var mark: (path: Path, color: Color)? {
        switch stage {
        case .needsYou: (Self.exclamation, Tokens.need)
        case .stuck: (Self.exclamation, Color(hex: 0x1A0806))
        case .finished, .done: (Self.check, Color(hex: 0x04210D))
        default: nil
        }
    }

    private static let exclamation = Path { path in
        path.move(to: CGPoint(x: 8, y: 4.8))
        path.addLine(to: CGPoint(x: 8, y: 8.4))
        path.move(to: CGPoint(x: 8, y: 11))
        path.addLine(to: CGPoint(x: 8.01, y: 11))
    }

    private static let check = Path { path in
        path.move(to: CGPoint(x: 5.3, y: 8.2))
        path.addLine(to: CGPoint(x: 7.2, y: 10.1))
        path.addLine(to: CGPoint(x: 10.8, y: 6.3))
    }

    private static func pie(_ fraction: Double) -> Path {
        Path { path in
            let center = CGPoint(x: 8, y: 8)
            path.move(to: center)
            path.addLine(to: CGPoint(x: 8, y: 4))
            path.addArc(center: center, radius: 4, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
            path.closeSubpath()
        }
    }
}
