import Foundation
import Observation

@MainActor
@Observable
public final class PlanUsagePoller {
    public typealias Fetch = @Sendable (String) async throws -> PlanUsage

    public static let baseBackoff: TimeInterval = 60
    public static let maximumBackoff: TimeInterval = 30 * 60

    public private(set) var usage: PlanUsage?
    public private(set) var lastUpdated: Date?
    public private(set) var needsSignIn = false
    public private(set) var backoffUntil: Date?
    public private(set) var lastError: String?

    @ObservationIgnored private let credentials: any PlanUsageCredentialSource
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let tick: Duration
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var isPolling = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(
        credentials: any PlanUsageCredentialSource = ClaudeCodeKeychainCredentials(),
        fetch: @escaping Fetch = { try await PlanUsageClient(token: $0).fetch() },
        tick: Duration = .seconds(90),
        clock: @escaping @MainActor () -> Date = { .now }
    ) {
        self.credentials = credentials
        self.fetch = fetch
        self.tick = tick
        self.clock = clock
    }

    public var isRunning: Bool { loop != nil }

    public func start() {
        guard loop == nil else { return }
        needsSignIn = false
        loop = Task { [weak self, tick] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: tick)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func refresh() async {
        await poll(explicitly: true)
    }

    public func poll() async {
        await poll(explicitly: false)
    }

    public func isBackingOff(at now: Date) -> Bool {
        backoffUntil.map { now < $0 } ?? false
    }

    private func poll(explicitly: Bool) async {
        guard !isPolling, explicitly || !needsSignIn, !isBackingOff(at: clock()) else { return }
        isPolling = true
        defer { isPolling = false }

        let cachedToken = token
        guard let token = readToken() else { return }
        do {
            record(try await fetch(token))
        } catch PlanUsageError.unauthorized where cachedToken != nil {
            self.token = nil
            guard let fresh = readToken(), fresh != token else {
                requireSignIn()
                return
            }
            do {
                record(try await fetch(fresh))
            } catch {
                handle(error)
            }
        } catch {
            handle(error)
        }
    }

    private func readToken() -> String? {
        if let token { return token }
        do {
            guard let stored = try credentials.accessToken() else {
                requireSignIn()
                return nil
            }
            token = stored
            return stored
        } catch {
            requireSignIn()
            return nil
        }
    }

    private func record(_ fetched: PlanUsage) {
        usage = fetched
        lastUpdated = clock()
        needsSignIn = false
        lastError = nil
        consecutiveFailures = 0
        backoffUntil = nil
    }

    private func handle(_ error: Error) {
        switch error {
        case PlanUsageError.unauthorized:
            requireSignIn()
        case PlanUsageError.rateLimited(let resetAt):
            registerFailure(resetAt: resetAt, message: PlanUsageError.rateLimited(resetAt: resetAt).localizedDescription)
        default:
            registerFailure(resetAt: nil, message: error.localizedDescription)
        }
    }

    private func requireSignIn() {
        token = nil
        usage = nil
        needsSignIn = true
        lastError = PlanUsageError.unauthorized.localizedDescription
    }

    private func registerFailure(resetAt: Date?, message: String) {
        consecutiveFailures += 1
        let now = clock()
        let exponential = min(Self.baseBackoff * pow(2, Double(consecutiveFailures - 1)), Self.maximumBackoff)
        let until = max(resetAt ?? now.addingTimeInterval(exponential), now.addingTimeInterval(Self.baseBackoff))
        backoffUntil = min(until, now.addingTimeInterval(Self.maximumBackoff))
        lastError = message
    }
}
