import Foundation

public enum GeneratedFiles {
    static let lockfileNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
        "Cargo.lock", "Gemfile.lock", "poetry.lock", "Pipfile.lock", "uv.lock", "pdm.lock", "composer.lock",
        "Podfile.lock", "Package.resolved", "go.sum", "mix.lock", "flake.lock", "pubspec.lock", "packages.lock.json",
        "gradle.lockfile", "Cartfile.resolved", "deno.lock",
    ]

    static let generatedDirectories: Set<String> = [
        "dist", "build", "node_modules", "__pycache__", "DerivedData", ".next", ".nuxt", ".svelte-kit",
        "coverage", ".gradle", "Pods", ".build",
    ]

    static let generatedBundleSuffixes = [".xcodeproj", ".xcworkspace"]

    static let generatedSuffixes = [
        ".min.js", ".min.css", ".min.mjs", ".js.map", ".css.map", ".pb.go", ".pb.swift", ".pb.cc", ".pb.h",
        "_pb2.py", "_pb2.pyi", "_pb2_grpc.py", ".pyc", ".pyo", ".g.dart", ".freezed.dart", ".designer.cs",
        ".generated.swift", ".generated.ts", ".generated.js", ".snap",
    ]

    public static func isGenerated(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        if lockfileNames.contains(name) { return true }
        let directories = components.dropLast()
        if directories.contains(where: generatedDirectories.contains) { return true }
        if directories.contains(where: { directory in generatedBundleSuffixes.contains { directory.hasSuffix($0) } }) { return true }
        let lowered = name.lowercased()
        return generatedSuffixes.contains { lowered.hasSuffix($0.lowercased()) }
    }
}
