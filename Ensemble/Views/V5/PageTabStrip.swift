import EnsembleCore
import EnsembleUI
import SwiftUI
import UniformTypeIdentifiers

struct PageTabStrip: View {
    static let height: CGFloat = 46

    @Environment(AppModel.self) private var model
    let isNarrow: Bool
    @State private var dragged: UUID?
    @State private var isNewPageMenuOpen = false

    var body: some View {
        let summaries = model.chatSummaries()
        let stages = Dictionary((summaries.open + summaries.closed).map { ($0.id, $0.stage) }, uniquingKeysWith: { first, _ in first })
        HStack(alignment: .bottom, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(model.pages.pages) { page in
                    PageTab(page: page, stage: page.kind.chatID.flatMap { stages[$0] })
                        .onDrag {
                            dragged = page.id
                            return NSItemProvider(object: page.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: PageTabDrop(target: page.id, dragged: $dragged, pages: model.pages))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages")
            newPageButton
                .frame(height: 38)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if isNarrow, let page = model.activePage, let chat = model.sideBarChat(for: page.kind), let project = model.project(withID: chat.projectId) {
                    ChatCardPill(project: project, chat: chat)
                }
                sideBarToggle
            }
            .frame(height: 38)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height, alignment: .bottom)
        .background(Tokens.side)
        .background(alignment: .bottom) { Rectangle().fill(Tokens.hair2).frame(height: 1) }
        .zIndex(1)
    }

    private var newPageButton: some View {
        Button { isNewPageMenuOpen.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .frame(width: 30, height: 30)
                .background(isNewPageMenuOpen ? Tokens.selection : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("New page")
        .accessibilityLabel("New page")
        .popover(isPresented: $isNewPageMenuOpen, arrowEdge: .bottom) {
            NewPageMenu { isNewPageMenuOpen = false }
        }
    }

    private var sideBarToggle: some View {
        @Bindable var pages = model.pages
        let label = pages.isSideBarOpen ? "Hide side bar" : "Show side bar"
        return Button { pages.isSideBarOpen.toggle() } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.text2)
                .frame(width: 30, height: 30)
                .background(pages.isSideBarOpen && !isNarrow ? Tokens.selection : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(label) (⌥⌘0)")
        .accessibilityLabel(label)
        .accessibilityValue(pages.isSideBarOpen ? "shown" : "hidden")
    }
}

private struct PageTab: View {
    static let maxWidth: CGFloat = 250

    @Environment(AppModel.self) private var model
    let page: MainPage
    let stage: ChatStage?
    @State private var isHovered = false

    var body: some View {
        let isActive = model.pages.activeID == page.id
        let title = model.title(of: page.kind)
        let attention = !isActive && (stage == .needsYou || stage == .stuck) ? stage : nil
        HStack(spacing: 4) {
            Button { model.pages.focus(page.id) } label: {
                HStack(spacing: 8) {
                    icon
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let attention {
                        Circle()
                            .fill(attention.color)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(attention.title)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
            Button { model.pages.close(page.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 22, height: 22)
                    .background(isHovered ? Tokens.hover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.6)
            .help("Close tab (⌘W)")
            .accessibilityLabel("Close \(title)")
        }
        .foregroundStyle(isActive ? Tokens.text : Tokens.text2)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(isActive ? Tokens.window : Tokens.fill, in: TopRoundedRectangle(radius: 10))
        .overlay { if isActive { TabOutline(radius: 10).stroke(Tokens.hair2) } }
        .offset(y: 1)
        .zIndex(isActive ? 1 : 0)
        .onHover { isHovered = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var icon: some View {
        switch page.kind {
        case .chat(_, let projectID):
            if let project = model.project(withID: projectID) { ProjectTile(project: project, size: 16) }
        default:
            Image(systemName: Self.symbol(for: page.kind))
                .font(.system(size: 12.5))
                .frame(width: 16)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Close") { model.pages.close(page.id) }
        Button("Close Others") { model.pages.closeOthers(page.id) }
            .disabled(model.pages.pages.count < 2)
        if let chatID = page.kind.chatID, let chat = try? model.database.task(id: chatID) {
            Divider()
            ChatRowMenu(chat: chat, rename: {})
        }
    }

    static func symbol(for kind: MainPageKind) -> String {
        switch kind {
        case .chat: "bubble.left"
        case .terminal: "terminal"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .tool(let tool, _): tool.systemImage
        case .run: "point.3.connected.trianglepath.dotted"
        case .agent: "person"
        case .spec: "doc.text"
        }
    }
}

private struct PageTabDrop: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let pages: MainPages

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { pages.move(dragged, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

private struct NewPageMenu: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("New chat", symbol: "square.and.pencil", key: "⌘N") { model.requestNewChat() }
            item("New terminal", symbol: "terminal", key: "⌃`") { model.openTerminal() }
            item("Open file…", symbol: "chevron.left.forwardslash.chevron.right", key: "⌘P") { model.openFileFinder() }
        }
        .padding(5)
        .frame(width: 230)
    }

    private func item(_ title: String, symbol: String, key: String, action: @escaping () -> Void) -> some View {
        NewPageMenuItem(title: title, symbol: symbol, key: key) {
            dismiss()
            action()
        }
        .disabled(model.currentProject == nil)
    }
}

private struct NewPageMenuItem: View {
    let title: String
    let symbol: String
    let key: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12.5)).frame(width: 16).opacity(0.85)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Text(key).font(.system(size: 12)).foregroundStyle(Tokens.text3)
            }
            .font(.system(size: 13))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isHovered ? Tokens.selection : .clear, in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
