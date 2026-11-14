import Foundation

public enum AppDefaults {
    nonisolated(unsafe) public static let store: UserDefaults = suite(for: ProcessInfo.processInfo.environment) ?? .standard

    static func suite(for environment: [String: String]) -> UserDefaults? {
        guard let name = suiteName(for: environment) else { return nil }
        return UserDefaults(suiteName: name)
    }

    public static func suiteName(for environment: [String: String]) -> String? {
        guard let custom = environment[AppPaths.dataDirectoryVariable], !custom.isEmpty else { return nil }
        let root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).standardizedFileURL.path
        return "dev.monoliti.Ensemble.data-dir." + SHA256Digest.hex(of: Data(root.utf8)).prefix(16)
    }
}
