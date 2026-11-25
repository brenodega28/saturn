import Foundation
import Network

@MainActor
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()

    init(update: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            Task { @MainActor in update(offline) }
        }
        monitor.start(queue: DispatchQueue(label: "app.saturn.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}
