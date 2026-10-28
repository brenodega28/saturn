import Foundation

extension Plan {
    public mutating func moveTask(id: String, by offset: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard tasks.indices.contains(destination) else { return }
        tasks.swapAt(index, destination)
    }

    public mutating func setSkills(_ skills: [String], forTask id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].skills = skills
    }

    public mutating func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
    }

    public var sizeDescription: String {
        let taskCount = tasks.count
        return "\(taskCount) task\(taskCount == 1 ? "" : "s")"
    }
}
