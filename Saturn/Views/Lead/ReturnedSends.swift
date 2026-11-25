import SaturnCore
import SwiftUI

extension View {
    func restoresReturnedSends(for target: LeadSendTarget?, perform restore: @escaping (PendingMessage) -> Void) -> some View {
        modifier(ReturnedSendRestorer(target: target, restore: restore))
    }
}

private struct ReturnedSendRestorer: ViewModifier {
    @Environment(DaemonWorkspace.self) private var workspace
    let target: LeadSendTarget?
    let restore: (PendingMessage) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: target.flatMap { workspace.returnedMessages.returned[$0] }, initial: true) {
            if let target, let message = workspace.returnedMessages.takeReturned(for: target) { restore(message) }
        }
    }
}
