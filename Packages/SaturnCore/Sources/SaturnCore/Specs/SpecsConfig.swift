import Foundation

public struct SpecsConfig: Sendable, Hashable, Codable {
    public static let fileName = "specs.yaml"
    public static let defaultFolder = "spec"

    public var folder: String

    public init(folder: String = SpecsConfig.defaultFolder) {
        self.folder = Self.clean(folder)
    }

    enum CodingKeys: String, CodingKey {
        case folder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.folder = Self.clean(try container.decodeIfPresent(String.self, forKey: .folder) ?? Self.defaultFolder)
    }

    public static func file(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: fileName)
    }

    public func directory(in repository: URL) -> URL {
        repository.appending(path: folder, directoryHint: .isDirectory)
    }

    static func clean(_ folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        let parts = trimmed.split(separator: "/").filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? defaultFolder : parts.joined(separator: "/")
    }
}
