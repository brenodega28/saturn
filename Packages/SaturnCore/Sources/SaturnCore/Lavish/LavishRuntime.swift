import Foundation

public struct LavishInvocation: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
}

public struct LavishProcessOutput: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: String

    public init(exitCode: Int32, standardOutput: Data, standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public typealias LavishLauncher = @Sendable (LavishInvocation) async throws -> LavishProcessOutput

public enum LavishError: Error, LocalizedError, Equatable {
    case packageMissing
    case nodeMissing
    case nodeTooOld(found: String, required: Int)
    case listenerActive
    case listenerReplaced
    case noSession
    case failed(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .packageMissing: "The bundled Lavish package is missing from this copy of Saturn."
        case .nodeMissing: "Node.js isn’t installed, so the spec opens read-only. Install Node \(LavishRuntime.requiredNodeMajor) or newer to review it in Lavish."
        case .nodeTooOld(let found, let required): "Node \(found) is too old for Lavish, so the spec opens read-only. Install Node \(required) or newer."
        case .listenerActive: "Another listener is already polling this Lavish session."
        case .listenerReplaced: "Another listener took over this Lavish session."
        case .noSession: "No Lavish session is open for this spec."
        case .failed(_, let message): message
        }
    }
}

public struct LavishPrompt: Sendable, Hashable, Codable {
    public var uid: String
    public var prompt: String
    public var selector: String
    public var tag: String
    public var text: String
    public var attachments: [LavishAttachment]

    public init(uid: String = "", prompt: String, selector: String = "", tag: String = "", text: String = "", attachments: [LavishAttachment] = []) {
        self.uid = uid
        self.prompt = prompt
        self.selector = selector
        self.tag = tag
        self.text = text
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case uid, prompt, selector, tag, text, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = Self.text(try? container.decodeIfPresent(LavishScalar.self, forKey: .uid))
        prompt = Self.text(try? container.decodeIfPresent(LavishScalar.self, forKey: .prompt))
        selector = Self.text(try? container.decodeIfPresent(LavishScalar.self, forKey: .selector))
        tag = Self.text(try? container.decodeIfPresent(LavishScalar.self, forKey: .tag))
        text = Self.text(try? container.decodeIfPresent(LavishScalar.self, forKey: .text))
        attachments = (try? container.decodeIfPresent([LavishAttachment].self, forKey: .attachments)) ?? []
    }

    static func text(_ scalar: LavishScalar?) -> String {
        scalar?.value ?? ""
    }
}

public struct LavishAttachment: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var path: String?

    public init(id: String = "", name: String? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(LavishScalar.self, forKey: .id))?.value ?? ""
        name = (try? container.decodeIfPresent(LavishScalar.self, forKey: .name))?.value
        path = (try? container.decodeIfPresent(LavishScalar.self, forKey: .path))?.value
    }
}

struct LavishScalar: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self) {
            value = String(number)
        } else if let flag = try? container.decode(Bool.self) {
            value = String(flag)
        } else {
            value = ""
        }
    }
}

public enum LavishPollResult: Sendable, Hashable {
    case feedback([LavishPrompt], sessionEnded: Bool)
    case ended
    case browserDisconnected
    case waiting
}

public struct LavishRuntime: Sendable {
    public static let version = "0.1.96"
    public static let owner = "saturn"
    public static let loopback = "127.0.0.1"

    public static var requiredNodeMajor: Int {
        guard let package = bundledPackage,
              let data = try? Data(contentsOf: package.appending(path: "package.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let range = manifest.engines?["node"] else { return 22 }
        return major(of: range) ?? 22
    }

    struct Manifest: Decodable {
        var version: String
        var engines: [String: String]?
    }

    public static var bundledPackage: URL? {
        guard let url = Bundle.module.url(forResource: "Lavish", withExtension: nil),
              FileManager.default.fileExists(atPath: url.appending(path: "dist/cli.mjs").path) else { return nil }
        return url
    }

    public let package: URL
    public let node: URL
    public let stateDirectory: URL
    public let baseEnvironment: [String: String]
    public let launch: LavishLauncher

    public init(package: URL, node: URL, stateDirectory: URL, baseEnvironment: [String: String] = [:], launch: @escaping LavishLauncher = LavishRuntime.launchProcess) {
        self.package = package
        self.node = node
        self.stateDirectory = stateDirectory
        self.baseEnvironment = baseEnvironment
        self.launch = launch
    }

    public static func locate(
        paths: AppPaths, environment: [String: String], package: URL? = LavishRuntime.bundledPackage,
        locator: ToolLocator? = nil, launch: @escaping LavishLauncher = LavishRuntime.launchProcess
    ) throws -> LavishRuntime {
        guard let package else { throw LavishError.packageMissing }
        guard let node = (locator ?? ToolLocator(environment: environment)).locate("node") else { throw LavishError.nodeMissing }
        return LavishRuntime(package: package, node: node, stateDirectory: paths.lavishState, baseEnvironment: environment, launch: launch)
    }

    public var cli: URL { package.appending(path: "dist/cli.mjs") }
    public var shim: URL { package.appending(path: "saturn-json.mjs") }

    public var port: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in stateDirectory.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return 43_870 + Int(hash % 100)
    }

    public var environment: [String: String] {
        var environment = baseEnvironment.filter { !$0.key.hasPrefix("LAVISH_AXI_") }
        environment["LAVISH_AXI_TELEMETRY"] = "0"
        environment["LAVISH_AXI_NO_OPEN"] = "1"
        environment["LAVISH_AXI_STATE_DIR"] = stateDirectory.path
        environment["LAVISH_AXI_HOST"] = Self.loopback
        environment["LAVISH_AXI_LINK_HOST"] = Self.loopback
        environment["LAVISH_AXI_PORT"] = String(port)
        return environment
    }

    public func invocation(_ arguments: [String]) -> LavishInvocation {
        LavishInvocation(executable: node, arguments: [shim.path, cli.path] + arguments, environment: environment)
    }

    public func open(file: URL) async throws -> URL {
        let output = try await run([file.path, "--no-open", "--reopen"])
        guard let link = output.session?.url, let url = URL(string: link) else {
            throw LavishError.failed(code: "NO_URL", message: "Lavish opened the spec but returned no session URL.")
        }
        return url
    }

    public func poll(file: URL, owner: String = LavishRuntime.owner, takeover: Bool = false) async throws -> LavishPollResult {
        let output = try await run(["poll", file.path, "--owner", owner] + (takeover ? ["--takeover"] : []))
        switch output.session?.status {
        case "feedback": return .feedback(output.prompts ?? [], sessionEnded: output.session?.sessionEnded ?? false)
        case "ended": return .ended
        case "browser_disconnected": return .browserDisconnected
        default: return .waiting
        }
    }

    public func reply(file: URL, text: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw HandoffError.missing("text") }
        _ = try await run(["reply", file.path, "--agent-reply", body])
    }

    public func end(file: URL) async throws {
        _ = try await run(["end", file.path])
    }

    struct Output: Decodable {
        struct Session: Decodable {
            var url: String?
            var status: String?
            var sessionEnded: Bool?

            enum CodingKeys: String, CodingKey {
                case url, status
                case sessionEnded = "session_ended"
            }
        }

        var session: Session?
        var prompts: [LavishPrompt]?
        var error: String?
        var code: String?
        var raw: String?
    }

    func run(_ arguments: [String]) async throws -> Output {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let result = try await launch(invocation(arguments))
        let output = try? JSONDecoder().decode(Output.self, from: result.standardOutput)
        if let code = output?.code {
            switch code {
            case "LISTENER_ACTIVE": throw LavishError.listenerActive
            case "LISTENER_REPLACED": throw LavishError.listenerReplaced
            case "NOT_FOUND": throw LavishError.noSession
            default: throw LavishError.failed(code: code, message: output?.error ?? "Lavish failed (\(code)).")
            }
        }
        guard result.exitCode == 0, let output else {
            let detail = [output?.raw, result.standardError].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }.first
            throw LavishError.failed(code: "EXIT_\(result.exitCode)", message: detail ?? "Lavish exited with code \(result.exitCode).")
        }
        return output
    }

    public static let launchProcess: LavishLauncher = { invocation in
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        let running = RunningProcess(process)
        return await withTaskCancellationHandler {
            async let data = read(output.fileHandleForReading)
            async let text = read(errors.fileHandleForReading)
            var status: Int32 = -1
            for await code in termination { status = code }
            return LavishProcessOutput(exitCode: status, standardOutput: await data, standardError: String(decoding: await text, as: UTF8.self))
        } onCancel: {
            running.stop()
        }
    }

    final class RunningProcess: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }

        func stop() {
            if process.isRunning { process.terminate() }
        }
    }

    static func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    public static func nodeVersion(_ node: URL, runner: CommandRunner) async -> String? {
        guard let result = try? await runner.run(node, ["--version"]), result.succeeded else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func major(of version: String) -> Int? {
        Int(version.drop { !$0.isNumber }.prefix { $0.isNumber })
    }
}

extension AppPaths {
    public var lavishState: URL { root.appending(path: "lavish", directoryHint: .isDirectory) }
}
