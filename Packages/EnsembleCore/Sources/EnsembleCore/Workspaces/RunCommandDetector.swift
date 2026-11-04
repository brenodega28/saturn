import Foundation

public struct DetectedRunCommand: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case packageScript(tool: String)
        case makefile
        case procfile
        case override
    }

    public var command: String
    public var source: Source

    public init(command: String, source: Source) {
        self.command = command
        self.source = source
    }

    public var label: String {
        source == .procfile ? "Procfile" : command
    }

    public var origin: String {
        switch source {
        case .packageScript(let tool): "package.json dev script, run with \(tool)"
        case .makefile: "Makefile dev target"
        case .procfile: "Procfile, every process at once"
        case .override: "Run command from Settings › Workspaces"
        }
    }
}

public enum RunCommandDetector {
    static let lockfiles: [(file: String, tool: String)] = [
        ("pnpm-lock.yaml", "pnpm"),
        ("yarn.lock", "yarn"),
        ("bun.lockb", "bun"),
        ("bun.lock", "bun"),
    ]

    static let makefileNames = ["GNUmakefile", "makefile", "Makefile"]

    public static func detect(in folder: URL) -> DetectedRunCommand? {
        packageScript(in: folder) ?? makefile(in: folder) ?? procfile(in: folder)
    }

    public static func resolve(override: String, in folder: URL) -> DetectedRunCommand? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return DetectedRunCommand(command: trimmed, source: .override) }
        return detect(in: folder)
    }

    static func packageScript(in folder: URL) -> DetectedRunCommand? {
        guard let data = try? Data(contentsOf: folder.appending(path: "package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = package["scripts"] as? [String: Any],
              let dev = scripts["dev"] as? String,
              !dev.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let tool = lockfiles.first { exists($0.file, in: folder) }?.tool ?? "npm"
        return DetectedRunCommand(command: "\(tool) run dev", source: .packageScript(tool: tool))
    }

    static func makefile(in folder: URL) -> DetectedRunCommand? {
        let target = /(?m)^(?:[\w.\/-]+[ \t]+)*dev(?:[ \t]+[\w.\/-]+)*[ \t]*::?(?!=)/
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        for name in makefileNames where present.contains(name) {
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else { continue }
            if text.contains(target) {
                return DetectedRunCommand(command: name == "Makefile" ? "make dev" : "make -f \(name) dev", source: .makefile)
            }
        }
        return nil
    }

    static func procfile(in folder: URL) -> DetectedRunCommand? {
        guard let text = try? String(contentsOf: folder.appending(path: "Procfile"), encoding: .utf8) else { return nil }
        let processes = procfileProcesses(text)
        guard !processes.isEmpty else { return nil }
        let script = processes.map { "(\($0.command)) &" }.joined(separator: "\n") + "\nwait"
        return DetectedRunCommand(command: script, source: .procfile)
    }

    static func procfileProcesses(_ text: String) -> [(name: String, command: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let command = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !command.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
            return (name, command)
        }
    }

    private static func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: name).path)
    }
}
