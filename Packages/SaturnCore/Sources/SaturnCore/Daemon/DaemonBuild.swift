import Foundation

public struct DaemonBuild: Codable, Sendable, Hashable {
    public var binaryHash: String

    public init(binaryHash: String) {
        self.binaryHash = binaryHash
    }

    public init?(executable: URL) {
        guard let data = try? Data(contentsOf: executable) else { return nil }
        self.init(binaryHash: SHA256Digest.hex(of: data))
    }

    public static func running(paths: AppPaths) -> DaemonBuild? {
        guard let data = try? Data(contentsOf: paths.daemonBuild) else { return nil }
        return try? JSONDecoder().decode(DaemonBuild.self, from: data)
    }

    public func record(paths: AppPaths) throws {
        try JSONEncoder().encode(self).write(to: paths.daemonBuild, options: .atomic)
    }
}
