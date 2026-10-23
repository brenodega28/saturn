import Foundation
import GRDB

extension AppDatabase {
    @discardableResult
    public func openProject(at url: URL, now: Date = .now) throws -> Project {
        let path = url.standardizedFileURL.path
        return try writer.write { db in
            if var project = try Project.filter(Project.Columns.path == path).fetchOne(db) {
                project.isOpen = true
                project.lastOpenedAt = now
                try project.update(db)
                return project
            }
            var project = Project(
                name: url.lastPathComponent,
                path: path,
                isOpen: true,
                createdAt: now,
                lastOpenedAt: now
            )
            try project.insert(db)
            return project
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
