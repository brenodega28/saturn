import AppKit
import Observation
import SwiftUI

struct StoredShortcut: Codable, Hashable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(_ shortcut: KeyboardShortcut) {
        key = shortcut.key.storageKey
        command = shortcut.modifiers.contains(.command)
        shift = shortcut.modifiers.contains(.shift)
        option = shortcut.modifiers.contains(.option)
        control = shortcut.modifiers.contains(.control)
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        let key: String? = switch event.keyCode {
        case 36: "return"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        case 48: "tab"
        case 49: "space"
        case 51: "delete"
        default: event.charactersIgnoringModifiers?.lowercased()
        }
        guard let key, !key.isEmpty else { return nil }
        self.key = key
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }

    var shortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent? = switch key {
        case "return": .return
        case "left": .leftArrow
        case "right": .rightArrow
        case "down": .downArrow
        case "up": .upArrow
        case "tab": .tab
        case "space": .space
        case "delete": .delete
        default: key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
        guard let equivalent else { return nil }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}

extension KeyEquivalent {
    var storageKey: String {
        switch self {
        case .return: "return"
        case .leftArrow: "left"
        case .rightArrow: "right"
        case .downArrow: "down"
        case .upArrow: "up"
        case .tab: "tab"
        case .space: "space"
        case .delete: "delete"
        default: String(character).lowercased()
        }
    }
}

@MainActor
@Observable
final class KeyBindings {
    static let shared = KeyBindings()
    private static let defaultsKey = "keyBindings.v1"

    private(set) var overrides: [String: StoredShortcut?] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: StoredShortcut?].self, from: data) {
            overrides = decoded
        }
    }

    func shortcut(for command: WorkbenchCommand) -> KeyboardShortcut? {
        if let override = overrides[command.id] {
            return override?.shortcut
        }
        return command.shortcut
    }

    func isCustomized(_ command: WorkbenchCommand) -> Bool {
        overrides[command.id] != nil
    }

    func set(_ shortcut: StoredShortcut?, for command: WorkbenchCommand) {
        if shortcut == command.shortcut.map(StoredShortcut.init) {
            overrides[command.id] = nil
        } else {
            overrides[command.id] = .some(shortcut)
        }
        save()
    }

    func reset(_ command: WorkbenchCommand) {
        overrides[command.id] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    func conflicts(in commands: [WorkbenchCommand]) -> [StoredShortcut: [WorkbenchCommand]] {
        var byShortcut: [StoredShortcut: [WorkbenchCommand]] = [:]
        for command in commands {
            guard let shortcut = shortcut(for: command) else { continue }
            byShortcut[StoredShortcut(shortcut), default: []].append(command)
        }
        return byShortcut.filter { $0.value.count > 1 }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct KeyBindingsEditor: View {
    @State private var query = ""
    @State private var recording: String?
    @State private var monitor: Any?

    var body: some View {
        let bindings = KeyBindings.shared
        let registry = WorkbenchRegistry.shared
        let menus = WorkbenchRegistry.menuBar + ["View.Navigator", "Context"]
        let all = registry.commands.filter { menus.contains($0.menu) }
        let conflicts = bindings.conflicts(in: all)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Filter commands", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Button("Restore Defaults") { bindings.resetAll() }.disabled(bindings.overrides.isEmpty)
            }
            List {
                ForEach(menus, id: \.self) { menu in
                    let commands = all.filter { $0.menu == menu && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
                        .sorted { ($0.section, $0.order, $0.title) < ($1.section, $1.order, $1.title) }
                    if !commands.isEmpty {
                        Section(menu == "View.Navigator" ? "Navigator" : menu == "Context" ? "Context menus" : menu) {
                            ForEach(commands) { command in
                                row(command, bindings: bindings, conflicts: conflicts)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Text("Click a shortcut, then press the new keys. Press ⌫ to remove it, or ⎋ to cancel.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .onDisappear(perform: stopRecording)
    }

    private func row(_ command: WorkbenchCommand, bindings: KeyBindings, conflicts: [StoredShortcut: [WorkbenchCommand]]) -> some View {
        let shortcut = bindings.shortcut(for: command)
        let clashes = shortcut.flatMap { conflicts[StoredShortcut($0)] }?.filter { $0.id != command.id } ?? []
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                if !clashes.isEmpty {
                    Text("Also used by \(clashes.map(\.title).joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            if bindings.isCustomized(command) {
                Button("Reset") { bindings.reset(command) }.buttonStyle(.borderless).font(.system(size: 11.5))
            }
            Button {
                recording == command.id ? stopRecording() : startRecording(command)
            } label: {
                Text(recording == command.id ? "Press keys…" : shortcut?.displayString ?? "None")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(command.title) shortcut: \(shortcut?.displayString ?? "none"). Change")
        }
    }

    private func startRecording(_ command: WorkbenchCommand) {
        stopRecording()
        recording = command.id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty {
                KeyBindings.shared.set(nil, for: command)
                stopRecording()
                return nil
            }
            guard let stored = StoredShortcut(event: event) else { return nil }
            KeyBindings.shared.set(stored, for: command)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
