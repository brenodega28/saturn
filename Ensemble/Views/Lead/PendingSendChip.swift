import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

struct PendingSendChip: View {
    @Environment(AppModel.self) private var model
    let target: PendingSendTarget?
    let onUndo: (PendingMessage) -> Void

    var body: some View {
        let holds = target.map(model.pendingSends.holds(for:)) ?? []
        if !holds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(holds) { hold in
                    PendingSendRow(hold: hold, undo: { undo(hold.id) })
                }
            }
            .background(EscapeKeyMonitor(onEscape: undoLatest))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func undo(_ id: UUID) {
        if let message = model.pendingSends.undo(id) { onUndo(message) }
    }

    private func undoLatest() -> Bool {
        guard !model.isPalettePresented, let target, let message = model.pendingSends.undoLatest(for: target) else { return false }
        onUndo(message)
        return true
    }
}

private struct PendingSendRow: View {
    let hold: PendingSends<PendingSendTarget>.Hold
    let undo: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let remaining = max(hold.deadline.timeIntervalSince(context.date), 0)
            let seconds = Int(remaining.rounded(.up))
            HStack(spacing: 10) {
                ProgressView(value: remaining, total: max(hold.deadline.timeIntervalSince(hold.scheduledAt), remaining, 0.1))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text("Sending in \(seconds)s…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                Text(preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Undo", action: undo)
                    .buttonStyle(.pill)
                    .help("Stop this message and put it back in the composer (Esc)")
                    .accessibilityLabel("Undo send")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)
            .background(Theme.fillRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sending in \(seconds) seconds: \(preview)")
        }
    }

    private var preview: String {
        let text = hold.message.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let count = hold.message.attachments.count
        let attachments = count == 0 ? "" : "\(count) attachment\(count == 1 ? "" : "s")"
        return [text, attachments].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct EscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEscape = onEscape
    }

    final class MonitorView: NSView {
        static let escapeKeyCode: UInt16 = 53
        var onEscape: () -> Bool = { false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isPlainEscape = event.keyCode == Self.escapeKeyCode
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty
                let windowNumber = event.windowNumber
                guard isPlainEscape else { return event }
                let handled = MainActor.assumeIsolated { self?.handlesEscape(inWindow: windowNumber) ?? false }
                return handled ? nil : event
            }
        }

        private func handlesEscape(inWindow windowNumber: Int) -> Bool {
            guard let window, window.windowNumber == windowNumber, window.attachedSheet == nil,
                  (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
            return onEscape()
        }
    }
}

extension View {
    func restoresReturnedSends(for target: PendingSendTarget?, perform restore: @escaping (PendingMessage) -> Void) -> some View {
        modifier(ReturnedSendRestorer(target: target, restore: restore))
    }
}

private struct ReturnedSendRestorer: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: PendingSendTarget?
    let restore: (PendingMessage) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: target.flatMap { model.pendingSends.returned[$0] }, initial: true) {
            if let target, let message = model.pendingSends.takeReturned(for: target) { restore(message) }
        }
    }
}
