import AppKit
import EnsembleCore
import EnsembleUI
import SwiftUI

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

    func cancelsHeldSendOnEscape(for target: PendingSendTarget?) -> some View {
        modifier(HeldSendEscapeCanceller(target: target))
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

private struct HeldSendEscapeCanceller: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: PendingSendTarget?

    func body(content: Content) -> some View {
        let isHolding = target.map { !model.pendingSends.holds(for: $0).isEmpty } ?? false
        content.background {
            if isHolding {
                EscapeKeyMonitor(onEscape: cancelLatest)
            }
        }
    }

    private func cancelLatest() -> Bool {
        guard !model.isPalettePresented, let target else { return false }
        return model.pendingSends.cancelLatest(for: target)
    }
}
