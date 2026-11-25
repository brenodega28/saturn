import Foundation
import Observation

@MainActor
@Observable
public final class LiveAgentSession: Identifiable {
    public nonisolated let id: Int64
    public internal(set) var agent: Agent
    @ObservationIgnored private weak var connection: DaemonConnection?
    private var loadedTranscript = Transcript()
    @ObservationIgnored private var streamedBytes: Int64 = 0
    @ObservationIgnored private var pendingBytes = Data()
    @ObservationIgnored private var bufferedLines: [String] = []
    @ObservationIgnored private var caughtUp = false
    @ObservationIgnored private var streaming: Task<Void, Never>?

    init(agent: Agent, connection: DaemonConnection) {
        self.id = agent.id ?? -1
        self.agent = agent
        self.connection = connection
    }

    public var transcript: Transcript {
        startStreaming()
        return loadedTranscript
    }

    var live: LiveAgent { connection?.live.agent(id) ?? LiveAgent() }

    public var isRunning: Bool { live.isRunning }
    public var isStopping: Bool { live.isStopping }
    public var isQueued: Bool { live.isQueued }
    public var canResume: Bool { live.canResume }
    public var isSettingUp: Bool { live.isSettingUp }
    public var setupFailed: Bool { live.setupFailed }
    public var isUpdatingMemory: Bool { live.isUpdatingMemory }
    public var queuedMessages: [String] { live.queuedMessages }
    public var lastOutputAt: Date? { live.lastOutputAt }
    public var retryingAt: Date? { live.retryingAt }
    public var apiRetry: LiveRetry? { live.apiRetry }

    public func send(_ message: String, images: [ChatAttachment] = []) {
        connection?.perform("Couldn’t send the message to \(AgentNaming.displayName(of: agent))", AgentCommands.Send(agentID: id, text: message, attachments: images))
    }

    public func pause() { perform(.pause, "pause") }
    public func resume() { perform(.resume, "resume") }
    public func stop() { perform(.stop, "stop") }
    public func restart() { perform(.restart, "restart") }
    public func takeOver() { perform(.takeOver, "take over") }
    public func handBack() { perform(.handBack, "hand back") }
    public func retrySetup() { perform(.retrySetup, "retry the setup of") }
    public func togglePin() { setPinned(!agent.isPinned) }

    public func setPinned(_ pinned: Bool) {
        agent.isPinned = pinned
        connection?.perform("Couldn’t pin \(AgentNaming.displayName(of: agent))", AgentCommands.SetPinned(agentID: id, pinned: pinned))
    }

    public func setModel(_ model: String) {
        connection?.perform("Couldn’t change the model of \(AgentNaming.displayName(of: agent))", AgentCommands.SetModel(agentID: id, model: model))
    }

    private func perform(_ action: AgentAction, _ verb: String) {
        connection?.perform("Couldn’t \(verb) \(AgentNaming.displayName(of: agent))", AgentCommands.Perform(agentID: id, action: action))
    }

    func startStreaming() {
        guard streaming == nil, let client = connection?.client, client.state.isConnected else { return }
        let offset = streamedBytes
        let events = client.fileEvents(.transcript, id: "\(id)", offset: offset, follow: true)
        streaming = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    guard let self else { return }
                    switch event {
                    case .data(let data): self.receive(data)
                    case .caughtUp: self.catchUp()
                    }
                }
            } catch {}
            self?.streaming = nil
        }
    }

    func stopStreaming() {
        streaming?.cancel()
        streaming = nil
    }

    func connectionResumed() {
        guard streaming == nil, caughtUp || streamedBytes > 0 else { return }
        startStreaming()
    }

    private func receive(_ data: Data) {
        streamedBytes += Int64(data.count)
        pendingBytes.append(data)
        var lines: [String] = []
        while let newline = pendingBytes.firstIndex(of: 0x0A) {
            let line = String(decoding: pendingBytes[pendingBytes.startIndex..<newline], as: UTF8.self)
            pendingBytes.removeSubrange(pendingBytes.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard !lines.isEmpty else { return }
        if caughtUp {
            var updated = loadedTranscript
            for line in lines {
                for event in ClaudeEvent.parse(line: line) { updated.apply(event) }
            }
            loadedTranscript = updated
        } else {
            bufferedLines += lines
        }
    }

    private func catchUp() {
        guard !caughtUp else { return }
        caughtUp = true
        loadedTranscript = Transcript(lines: bufferedLines)
        bufferedLines = []
    }
}
