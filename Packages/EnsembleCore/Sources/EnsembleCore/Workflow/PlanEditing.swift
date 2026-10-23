import Foundation

extension Plan {
    public static let agentsPerTask = 1...4

    public mutating func moveTask(id: String, by offset: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard tasks.indices.contains(destination) else { return }
        tasks.swapAt(index, destination)
    }

    public mutating func setRole(_ role: String, forTask id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].role = role
    }

    public mutating func setCount(_ count: Int, forTask id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].count = min(max(count, Self.agentsPerTask.lowerBound), Self.agentsPerTask.upperBound)
    }

    public mutating func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
    }

    public var sizeDescription: String {
        let taskCount = tasks.count
        let agents = agentCount
        return "\(taskCount) task\(taskCount == 1 ? "" : "s") · \(agents) agent\(agents == 1 ? "" : "s")"
    }
}
