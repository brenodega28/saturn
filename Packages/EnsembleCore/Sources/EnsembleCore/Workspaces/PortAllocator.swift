import Foundation

public enum PortAllocator {
    public static let highestPort = 65535

    public static func port(base: Int, taken: Set<Int>) -> Int? {
        guard base > 0, base <= highestPort else { return nil }
        return (base...highestPort).first { !taken.contains($0) }
    }

    public static func takenPorts(by agents: [Agent]) -> Set<Int> {
        Set(agents.filter { $0.archivedAt == nil }.compactMap(\.port))
    }
}
