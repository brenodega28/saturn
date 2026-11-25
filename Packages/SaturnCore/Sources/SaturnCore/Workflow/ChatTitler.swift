import Foundation

@MainActor
public final class ChatTitler {
    public struct Launch: Sendable {
        public var executable: URL
        public var environment: [String: String]

        public init(executable: URL, environment: [String: String]) {
            self.executable = executable
            self.environment = environment
        }
    }

    let database: AppDatabase
    let timeout: Duration
    private let launch: @MainActor () -> Launch?

    public init(database: AppDatabase, timeout: Duration = .seconds(20), launch: @escaping @MainActor () -> Launch?) {
        self.database = database
        self.timeout = timeout
        self.launch = launch
    }

    public convenience init(runtime: AgentRuntime, timeout: Duration = .seconds(20)) {
        self.init(database: runtime.database, timeout: timeout) { [weak runtime] in
            guard let runtime, let executable = runtime.claudeExecutable,
                  let environment = try? runtime.launchEnvironment() else { return nil }
            return Launch(executable: executable, environment: environment)
        }
    }

    nonisolated static let maxPromptCharacters = 2000

    nonisolated static func prompt(for text: String) -> String {
        """
        Write a 3 to 6 word title that summarizes this request to a coding assistant. \
        Reply with the title only, in plain text, with no quotes and no trailing punctuation.

        Request:
        \(text.prefix(maxPromptCharacters))
        """
    }

    nonisolated static func arguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--model", AgentModel.haiku.rawValue,
            "--output-format", "text",
            "--tools", "",
            "--no-session-persistence",
            "--setting-sources", "",
            "--strict-mcp-config",
        ]
    }

    public func generateTitle(for chat: Chat, text: String) async {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = chat.id, !request.isEmpty, let launch = launch(),
              let reply = await run(launch, arguments: Self.arguments(prompt: Self.prompt(for: request))),
              let title = Self.cleanTitle(reply), title != chat.title else { return }
        _ = try? database.renameChatIfUntitled(id: id, from: chat.title, to: title)
    }

    private func run(_ launch: Launch, arguments: [String]) async -> String? {
        let runner = CommandRunner(environment: launch.environment)
        let directory = FileManager.default.temporaryDirectory
        let timeout = timeout
        let result = await firstOf(
            { try? await runner.run(launch.executable, arguments, in: directory) },
            { try? await Task.sleep(for: timeout); return nil }
        )
        guard let result, result.succeeded else { return nil }
        return result.standardOutput
    }

    private func firstOf<T: Sendable>(
        _ first: @escaping @Sendable () async -> T?, _ second: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task.detached { once.resume(await first()) }
            Task.detached { once.resume(await second()) }
        }
    }

    nonisolated public static func cleanTitle(_ reply: String) -> String? {
        let markdown = CharacterSet(charactersIn: "#*_`")
        guard let line = reply.split(whereSeparator: \.isNewline)
            .map({ String($0.unicodeScalars.filter { !markdown.contains($0) }).trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var title = line
        var previous = ""
        while title != previous {
            previous = title
            title = title.trimmingCharacters(in: noise)
            if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)) }
            title = title.trimmingSuffix(in: trailingPunctuation)
        }
        let capped = LeadRequest.title(for: title)
        return capped.isEmpty ? nil : capped
    }

    nonisolated private static let noise = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’«»"))
    nonisolated private static let trailingPunctuation = CharacterSet(charactersIn: ".!?:;")
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private extension String {
    func trimmingSuffix(in set: CharacterSet) -> String {
        var scalars = Substring(self).unicodeScalars
        while let last = scalars.last, set.contains(last) { scalars.removeLast() }
        return String(scalars)
    }
}
