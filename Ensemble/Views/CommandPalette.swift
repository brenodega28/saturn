import EnsembleUI
import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let action: () -> Void
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                    TextField("Search or run a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isFocused)
                        .onSubmit(runHighlighted)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Divider().overlay(Theme.hairline)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                Button {
                                    run(command)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: command.systemImage).frame(width: 18)
                                        Text(command.title)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 34)
                                    .background(index == highlighted ? Theme.accent.opacity(0.28) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .id(command.id)
                            }
                            if results.isEmpty {
                                Text("No matching commands").foregroundStyle(Theme.tertiaryText).padding(16)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: highlighted) {
                        if results.indices.contains(highlighted) { proxy.scrollTo(results[highlighted].id) }
                    }
                }
            }
            .frame(width: 560)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .padding(.top, 90)
        }
        .defaultFocus($isFocused, true)
        .task { isFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var results: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var commands: [PaletteCommand] {
        var commands = [
            PaletteCommand(id: "open", title: "Open Folder…", systemImage: "folder") { model.isOpenPanelPresented = true },
            PaletteCommand(id: "clone", title: "Clone Repository…", systemImage: "arrow.triangle.branch") { model.isClonePresented = true },
            PaletteCommand(id: "inbox", title: "Go to Inbox", systemImage: "tray") { model.selection = .inbox },
            PaletteCommand(id: "usage", title: "Go to Usage", systemImage: "chart.bar") { model.selection = .usage },
            PaletteCommand(id: "quality", title: "Go to Quality", systemImage: "gauge.with.dots.needle.33percent") { model.selection = .quality },
        ]
        if let project = model.selectedProject {
            commands += ProjectTab.allCases.map { tab in
                PaletteCommand(id: "tab-\(tab.rawValue)", title: "Go to \(tab.title)", systemImage: "rectangle.on.rectangle") {
                    model.setTab(tab, for: project)
                }
            }
        }
        commands += model.openProjects.compactMap { project in
            project.id.map { id in
                PaletteCommand(id: "project-\(id)", title: "Switch to \(project.name)", systemImage: "folder") {
                    model.selection = .project(id)
                }
            }
        }
        commands.append(PaletteCommand(id: "worktrees", title: "Debug: Worktrees…", systemImage: "hammer") {
            openWindow(id: WindowID.debugWorktrees)
        })
        return commands
    }

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ command: PaletteCommand) {
        dismiss()
        command.action()
    }

    private func dismiss() {
        model.isPalettePresented = false
    }
}
