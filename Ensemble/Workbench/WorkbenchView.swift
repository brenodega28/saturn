import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct WorkbenchView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("workbench.main.v1") private var stored: Data?
    @State private var keyMonitor: Any?
    @State private var state = WorkbenchState()
    @State private var hasRestored = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if state.isShowing(.navigator) {
                    NavigatorPane()
                        .frame(width: state.navigatorWidth)
                    PaneDivider(axis: .vertical, length: $state.navigatorWidth, range: 220...460)
                }
                VStack(spacing: 0) {
                    EditorArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if state.isShowing(.bottom) {
                        PaneDivider(axis: .horizontal, length: $state.bottomHeight, range: 120...560, grows: .up)
                        BottomPanel()
                            .frame(height: state.bottomHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.isShowing(.inspector) {
                    PaneDivider(axis: .vertical, length: $state.inspectorWidth, range: 240...460, grows: .left)
                    InspectorPane()
                        .frame(width: state.inspectorWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .background(Theme.windowBackground)
        .overlay(alignment: .top) {
            if state.isLibraryShown {
                LibraryPanel { state.isLibraryShown = false }
                    .padding(.top, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .toolbar { WorkbenchToolbar(isHidden: state.isToolbarHidden) }
        .toolbar(removing: .title)
        .toolbarBackground(Color(hex: 0x2C2C32), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar(state.isToolbarHidden ? .hidden : .visible, for: .windowToolbar)
        .environment(state)
        .focusedSceneValue(\.workbench, state)
        .sheet(isPresented: $model.isNewAgentPresented) {
            if let project = model.currentProject {
                NewAgentSheet(project: project)
            }
        }
        .onAppear(perform: restore)
        .onAppear { model.activeWorkbench = state }
        .sheet(item: $model.pinPrompt) { prompt in PinPromptSheet(prompt: prompt) }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: model.currentEditorItem, initial: true) { _, item in
            if let item, model.isAvailable(item) { state.open(item) }
        }
        .onChange(of: state.active) { _, item in
            if let item {
                model.apply(item)
            } else {
                model.selection = nil
            }
        }
        .onChange(of: model.openProjects.compactMap(\.id)) { _, ids in
            state.remove { $0.project.map { !ids.contains($0) } ?? false }
        }
        .onChange(of: state.snapshot.encoded) { _, data in
            if hasRestored { stored = data }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue.hasPrefix(WindowID.main) == true,
                  let command = WorkbenchShortcuts.command(for: event) else { return event }
            let context = CommandContext(model: model, workbench: state, openWindow: nil)
            guard command.isEnabled(context) else { return event }
            command.perform(context)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func restore() {
        guard !hasRestored else { return }
        if let stored, let snapshot = try? JSONDecoder().decode(WorkbenchState.Snapshot.self, from: stored) {
            state.restore(snapshot)
        }
        state.remove { !model.isAvailable($0) }
        if let item = model.currentEditorItem, model.isAvailable(item) { state.open(item, recordingHistory: false) }
        hasRestored = true
    }
}

extension WorkbenchState.Snapshot {
    var encoded: Data? {
        try? JSONEncoder().encode(self)
    }
}

enum WorkbenchShortcuts {
    static let overriding = ["navigate.close-tab", "view.bottom"]

    @MainActor
    static func command(for event: NSEvent) -> WorkbenchCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return overriding.compactMap(WorkbenchRegistry.shared.command).first { command in
            guard let shortcut = KeyBindings.shared.shortcut(for: command) else { return false }
            return String(shortcut.key.character) == key && shortcut.modifiers.eventFlags == modifiers
        }
    }
}

extension EventModifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

extension FocusedValues {
    @Entry var workbench: WorkbenchState?
}

struct PaneDivider: View {
    enum Growth {
        case right
        case left
        case down
        case up
    }

    let axis: Axis
    @Binding var length: Double
    let range: ClosedRange<Double>
    var grows: Growth = .right
    @State private var start: Double?

    init(axis: Axis, length: Binding<Double>, range: ClosedRange<Double>, grows: Growth? = nil) {
        self.axis = axis
        self._length = length
        self.range = range
        self.grows = grows ?? (axis == .vertical ? .right : .down)
    }

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 7 : nil, height: axis == .horizontal ? 7 : nil)
                    .contentShape(.rect)
                    .pointerStyle(axis == .vertical ? .columnResize : .rowResize)
                    .gesture(drag)
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let base = start ?? length
                if start == nil { start = length }
                let delta: Double = switch grows {
                case .right: value.translation.width
                case .left: -value.translation.width
                case .down: value.translation.height
                case .up: -value.translation.height
                }
                length = min(max(base + delta, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in start = nil }
    }
}
