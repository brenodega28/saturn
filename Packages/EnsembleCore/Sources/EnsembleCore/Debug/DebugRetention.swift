#if DEBUG
import Foundation

struct DebugRetention {
    static let groups = ["runs", "chats"]

    struct Folder {
        let url: URL
        let size: Int64
        let modifiedAt: Date
        let createdAt: Date
    }

    let root: URL
    let limit: Int64
    let promptTouchInterval: TimeInterval

    @discardableResult
    func enforce(protecting protected: Set<URL> = []) -> [URL] {
        let folders = Self.groups.flatMap { scan(group: $0) }
        let looseSize = Self.size(of: root, skipping: Set(Self.groups.map { root.appending(path: $0) }))
        var total = folders.reduce(looseSize) { $0 + $1.size }
        guard total > limit else { return [] }
        let protectedPaths = Set(protected.map(\.standardizedFileURL.path))
        let ordered = folders.sorted { lhs, rhs in
            let lhsProtected = protectedPaths.contains(lhs.url.standardizedFileURL.path)
            let rhsProtected = protectedPaths.contains(rhs.url.standardizedFileURL.path)
            if lhsProtected != rhsProtected { return !lhsProtected }
            return lhs.modifiedAt < rhs.modifiedAt
        }
        var deleted: [URL] = []
        var kept = ordered
        for folder in ordered where total > limit {
            guard (try? FileManager.default.removeItem(at: folder.url)) != nil else { continue }
            total -= folder.size
            deleted.append(folder.url)
            kept.removeAll { $0.url == folder.url }
        }
        if let oldest = kept.map(\.createdAt).min() {
            removePrompts(olderThan: oldest.addingTimeInterval(-promptTouchInterval))
        }
        return deleted
    }

    private func removePrompts(olderThan cutoff: Date) {
        let prompts = root.appending(path: "prompts", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: prompts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func scan(group: String) -> [Folder] {
        let directory = root.appending(path: group, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            let (size, latest) = Self.sizeAndLatestModification(of: url)
            let modified = max(latest ?? .distantPast, values.contentModificationDate ?? .distantPast)
            return Folder(url: url, size: size, modifiedAt: modified, createdAt: values.creationDate ?? modified)
        }
    }

    private static func size(of directory: URL, skipping skipped: Set<URL>) -> Int64 {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        return entries.reduce(0) { total, url in
            guard !skipped.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) else { return total }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return total + sizeAndLatestModification(of: url).size
            }
            return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func sizeAndLatestModification(of directory: URL) -> (size: Int64, latest: Date?) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return (0, nil) }
        var size: Int64 = 0
        var latest: Date?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            size += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate, modified > (latest ?? .distantPast) { latest = modified }
        }
        return (size, latest)
    }
}
#endif
