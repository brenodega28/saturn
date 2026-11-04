import AppKit
import SwiftUI

extension View {
    func insetsWindowButtons(leading: CGFloat, centerFromTop: CGFloat) -> some View {
        background(WindowButtonInset(leading: leading, centerFromTop: centerFromTop))
    }
}

private struct WindowButtonInset: NSViewRepresentable {
    let leading: CGFloat
    let centerFromTop: CGFloat

    func makeNSView(context: Context) -> InsetView {
        let view = InsetView()
        view.placement = WindowButtonPlacement(leading: leading, centerFromTop: centerFromTop)
        return view
    }

    func updateNSView(_ view: InsetView, context: Context) {
        view.placement = WindowButtonPlacement(leading: leading, centerFromTop: centerFromTop)
    }

    static func dismantleNSView(_ view: InsetView, coordinator: ()) {
        view.detach()
    }

    final class InsetView: NSView {
        var placement = WindowButtonPlacement(leading: 0, centerFromTop: 0) {
            didSet { if placement != oldValue { reposition() } }
        }
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?
        private var isRepositioning = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else { return }
            detach()
            guard let window else { return }
            attach(to: window)
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let observedWindow {
                Self.buttons(of: observedWindow).first?.superview?.needsLayout = true
            }
            observedWindow = nil
        }

        private func attach(to window: NSWindow) {
            observedWindow = window
            let center = NotificationCenter.default
            let windowEvents: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,
            ]
            for name in windowEvents {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                })
            }
            for button in Self.buttons(of: window) {
                button.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                })
            }
            reposition()
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        override func layout() {
            super.layout()
            reposition()
        }

        private func reposition() {
            guard !isRepositioning, let window = observedWindow, !window.styleMask.contains(.fullScreen) else { return }
            let buttons = Self.buttons(of: window)
            guard let close = buttons.first, let container = close.superview else { return }
            isRepositioning = true
            defer { isRepositioning = false }
            let targetInWindow = NSPoint(x: placement.leading, y: window.frame.height - placement.centerFromTop)
            let target = container.convert(targetInWindow, from: nil)
            let dx = target.x - close.frame.minX
            let dy = target.y - close.frame.midY
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
            for button in buttons where button.superview === container {
                button.setFrameOrigin(NSPoint(x: button.frame.minX + dx, y: button.frame.minY + dy))
            }
        }

        private static func buttons(of window: NSWindow) -> [NSButton] {
            [.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        }
    }
}

private struct WindowButtonPlacement: Equatable {
    let leading: CGFloat
    let centerFromTop: CGFloat
}
