import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func openProject(at url: URL, now: Date = .now) throws -> Project {
        try openProject(path: url.standardizedFileURL.path, host: nil, name: url.lastPathComponent, now: now)
    }

    @discardableResult
    public func openRemoteProject(path: String, host: String, now: Date = .now) throws -> Project {
        let name = path.split(separator: "/").last.map(String.init) ?? host
        return try openProject(path: path, host: host, name: name, now: now)
    }

    private func openProject(path: String, host: String?, name: String, now: Date) throws -> Project {
        try writer.write { db in
            if var project = try Project.filter(Project.Columns.path == path && Project.Columns.host == host).fetchOne(db) {
                project.isOpen = true
                project.lastOpenedAt = now
                try project.update(db)
                return project
            }
            var project = Project(name: name, path: path, host: host, isOpen: true, createdAt: now, lastOpenedAt: now)
            try project.insert(db)
            return project
        }
    }

    public func project(id: Int64) throws -> Project? {
        try writer.read { db in try Project.fetchOne(db, id: id) }
    }

    public func updateSettings(_ settings: ProjectSettings, forProject id: Int64) throws {
        try writer.write { db in
            guard var project = try Project.fetchOne(db, id: id) else { return }
            project.settings = settings
            try project.update(db)
        }
    }

    public func renameProject(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try writer.write { db in
            try Project.filter(id: id).updateAll(db, Project.Columns.name.set(to: trimmed))
        }
    }

    public func closeProject(id: Int64) throws {
        _ = try writer.write { db in
            try Project.filter(id: id).updateAll(db, Project.Columns.isOpen.set(to: false))
        }
    }

    public func forgetProject(id: Int64) throws {
        _ = try writer.write { db in
            try Project.deleteOne(db, id: id)
        }
    }

    public func openProjects() throws -> [Project] {
        try writer.read { db in
            try Project
                .filter(Project.Columns.isOpen == true)
                .order(Project.Columns.name.collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func recentProjects(limit: Int = 10) throws -> [Project] {
        try writer.read { db in
            try Project
                .order(Project.Columns.lastOpenedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func spend(since start: Date) throws -> Double {
        try writer.read { db in
            try UsageEntry
                .filter(UsageEntry.Columns.recordedAt >= start)
                .select(sum(UsageEntry.Columns.costUSD), as: Double?.self)
                .fetchOne(db) ?? nil
        } ?? 0
    }
}
