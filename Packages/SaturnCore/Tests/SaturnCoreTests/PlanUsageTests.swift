import Foundation
import Synchronization
import Testing
@testable import SaturnCore

struct PlanUsageParsingTests {
    static let realisticPayload = """
        {
          "five_hour": {"utilization": 27, "resets_at": "2026-10-28T22:10:00.965991+00:00", "limit_dollars": null, "used_dollars": null},
          "seven_day": {"utilization": 21.4, "resets_at": "2026-11-03T01:00:00+00:00", "locked_reason": null},
          "seven_day_opus": null,
          "seven_day_oauth_apps": null,
          "extra_usage": {"is_enabled": false, "utilization": null},
          "limits": [{"kind": "session", "percent": 27}]
        }
        """

    @Test func parsesTheSessionAndWeekWindows() throws {
        let usage = try PlanUsage.parse(Data(Self.realisticPayload.utf8))
        #expect(usage.session?.utilization == 27)
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_793_225_400))
        #expect(usage.week?.utilization == 21.4)
        #expect(usage.week?.resetsAt == Date(timeIntervalSince1970: 1_793_667_600))
    }

    @Test func treatsNullAndMissingWindowsAsAbsent() throws {
        let nullWindows = try PlanUsage.parse(Data(#"{"five_hour": null, "other": 1}"#.utf8))
        #expect(nullWindows == PlanUsage())
        #expect(nullWindows.isEmpty)

        let nullUtilization = try PlanUsage.parse(Data(#"{"five_hour": {"utilization": null, "resets_at": null}, "seven_day": {"utilization": 5}}"#.utf8))
        #expect(nullUtilization.session == nil)
        #expect(nullUtilization.week == PlanUsageWindow(utilization: 5, resetsAt: nil))
    }

    @Test func readsResetTimesWithAndWithoutFractionalSeconds() {
        let whole = Date(timeIntervalSince1970: 1_793_667_600)
        #expect(PlanUsage.date(fromISO8601: "2026-11-03T01:00:00+00:00") == whole)
        #expect(PlanUsage.date(fromISO8601: "2026-11-03T01:00:00Z") == whole)
        #expect(PlanUsage.date(fromISO8601: "2026-11-03T01:00:00.123Z") == whole)
        #expect(PlanUsage.date(fromISO8601: "2026-11-03T03:00:00.966010+02:00") == whole)
        #expect(PlanUsage.date(fromISO8601: "next tuesday") == nil)
    }

    @Test func rejectsDataThatIsNotAUsageObject() {
        #expect(throws: PlanUsageError.self) { try PlanUsage.parse(Data("[]".utf8)) }
        #expect(throws: PlanUsageError.self) { try PlanUsage.parse(Data("<html>".utf8)) }
    }

    @Test func readsTheAccessTokenFromClaudeCodeCredentials() {
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat-test", "refreshToken": "r", "expiresAt": 1}, "mcpOAuth": {}}"#
        #expect(ClaudeCodeKeychainCredentials.accessToken(fromCredentials: Data(json.utf8)) == "sk-ant-oat-test")
        #expect(ClaudeCodeKeychainCredentials.accessToken(fromCredentials: Data(#"{"claudeAiOauth": {"accessToken": ""}}"#.utf8)) == nil)
        #expect(ClaudeCodeKeychainCredentials.accessToken(fromCredentials: Data("not json".utf8)) == nil)
    }
}

final class FakeUsageTransport: Sendable {
    private let state = Mutex<(replies: [(Int, [String: String], String)], requests: [URLRequest])>(([], []))

    func enqueue(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
        state.withLock { $0.replies.append((status, headers, body)) }
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    var transport: PlanUsageClient.Transport {
        { [self] request in
            let (status, headers, body) = state.withLock { state in
                state.requests.append(request)
                return state.replies.isEmpty ? (599, [:], "{}") : state.replies.removeFirst()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

struct PlanUsageClientTests {
    let fake = FakeUsageTransport()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func client() -> PlanUsageClient {
        let now = now
        return PlanUsageClient(token: "sk-ant-oat-secret", transport: fake.transport, now: { now })
    }

    @Test func sendsClaudeCodesHeaders() async throws {
        fake.enqueue(200, PlanUsageParsingTests.realisticPayload)
        let usage = try await client().fetch()
        #expect(usage.session?.utilization == 27)

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url == URL(string: "https://api.anthropic.com/api/oauth/usage"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat-secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test(arguments: [401, 403])
    func mapsRejectedTokensToUnauthorized(status: Int) async {
        fake.enqueue(status, #"{"error": {"type": "authentication_error"}}"#)
        await #expect(throws: PlanUsageError.unauthorized) { try await client().fetch() }
    }

    @Test func mapsRateLimitsWithAndWithoutRetryAfter() async {
        fake.enqueue(429, headers: ["retry-after": "120"])
        fake.enqueue(429)
        await #expect(throws: PlanUsageError.rateLimited(resetAt: now.addingTimeInterval(120))) { try await client().fetch() }
        await #expect(throws: PlanUsageError.rateLimited(resetAt: nil)) { try await client().fetch() }
    }

    @Test func mapsOtherStatusesAndBadBodiesToFailed() async {
        fake.enqueue(500)
        fake.enqueue(200, "not json")
        for _ in 0..<2 {
            do {
                _ = try await client().fetch()
                Issue.record("Expected a failure")
            } catch PlanUsageError.failed(let message) {
                #expect(!message.contains("sk-ant-oat-secret"))
            } catch {
                Issue.record("Unexpected \(error)")
            }
        }
    }
}

final class CountingCredentials: PlanUsageCredentialSource {
    private let state = Mutex<(tokens: [String?], reads: Int)>(([], 0))

    init(_ tokens: String?...) {
        state.withLock { $0.tokens = tokens }
    }

    var reads: Int {
        state.withLock { $0.reads }
    }

    func accessToken() throws -> String? {
        state.withLock { state in
            state.reads += 1
            return state.tokens.count > 1 ? state.tokens.removeFirst() : state.tokens.first ?? nil
        }
    }
}

final class FakeUsageFetcher: Sendable {
    private let state = Mutex<(outcomes: [Result<PlanUsage, PlanUsageError>], tokens: [String])>(([], []))

    func enqueue(_ outcomes: Result<PlanUsage, PlanUsageError>...) {
        state.withLock { $0.outcomes.append(contentsOf: outcomes) }
    }

    var tokens: [String] {
        state.withLock { $0.tokens }
    }

    var fetch: PlanUsagePoller.Fetch {
        { [self] token in
            try state.withLock { state in
                state.tokens.append(token)
                return state.outcomes.isEmpty ? .failure(.failed("no outcome")) : state.outcomes.removeFirst()
            }.get()
        }
    }
}

@MainActor
final class PollerClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(minutes: Double) {
        now = now.addingTimeInterval(minutes * 60)
    }
}

@MainActor
struct PlanUsagePollerTests {
    let fetcher = FakeUsageFetcher()
    let clock = PollerClock()
    let sample = PlanUsage(session: PlanUsageWindow(utilization: 42), week: PlanUsageWindow(utilization: 18))

    func makePoller(_ credentials: CountingCredentials) -> PlanUsagePoller {
        let clock = clock
        return PlanUsagePoller(credentials: credentials, fetch: fetcher.fetch, clock: { clock.now })
    }

    @Test func storesUsageAndCachesTheToken() async {
        let credentials = CountingCredentials("token-a")
        let poller = makePoller(credentials)
        fetcher.enqueue(.success(sample), .success(sample))

        await poller.poll()
        clock.advance(minutes: 1.5)
        await poller.poll()

        #expect(poller.usage == sample)
        #expect(poller.lastUpdated == clock.now)
        #expect(!poller.needsSignIn)
        #expect(credentials.reads == 1)
        #expect(fetcher.tokens == ["token-a", "token-a"])
    }

    @Test func backsOffExponentiallyUpToThirtyMinutes() async throws {
        let poller = makePoller(CountingCredentials("token-a"))
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            fetcher.enqueue(.failure(.failed("HTTP 500")))
            await poller.poll()
            let until = try #require(poller.backoffUntil)
            delays.append(until.timeIntervalSince(clock.now))
            await poller.poll()
            #expect(fetcher.tokens.count == delays.count)
            clock.now = until
        }
        #expect(delays == [60, 120, 240, 480, 960, 1800, 1800])

        fetcher.enqueue(.success(sample))
        await poller.poll()
        #expect(poller.backoffUntil == nil)
        #expect(poller.usage == sample)
    }

    @Test func honoursRateLimitResetsWithinTheCap() async {
        let poller = makePoller(CountingCredentials("token-a"))
        fetcher.enqueue(.failure(.rateLimited(resetAt: clock.now.addingTimeInterval(300))))
        await poller.poll()
        #expect(poller.backoffUntil == clock.now.addingTimeInterval(300))

        clock.advance(minutes: 5)
        fetcher.enqueue(.failure(.rateLimited(resetAt: clock.now.addingTimeInterval(7200))))
        await poller.poll()
        #expect(poller.backoffUntil == clock.now.addingTimeInterval(PlanUsagePoller.maximumBackoff))
    }

    @Test func stopsReadingTheKeychainAfterUnauthorizedUntilRefresh() async {
        let credentials = CountingCredentials("token-a")
        let poller = makePoller(credentials)
        fetcher.enqueue(.success(sample), .failure(.unauthorized))

        await poller.poll()
        clock.advance(minutes: 1.5)
        await poller.poll()

        #expect(poller.needsSignIn)
        #expect(poller.usage == nil)
        #expect(credentials.reads == 2)
        #expect(fetcher.tokens == ["token-a", "token-a"])

        for _ in 0..<5 {
            clock.advance(minutes: 10)
            await poller.poll()
        }
        #expect(credentials.reads == 2)
        #expect(fetcher.tokens.count == 2)

        fetcher.enqueue(.success(sample))
        await poller.refresh()
        #expect(credentials.reads == 3)
        #expect(!poller.needsSignIn)
        #expect(poller.usage == sample)
    }

    @Test func activationDoesNotReadTheKeychainWhileSignInIsNeeded() async {
        let credentials = CountingCredentials("token-a")
        let poller = makePoller(credentials)
        fetcher.enqueue(.failure(.unauthorized))
        await poller.poll()
        #expect(poller.needsSignIn)
        #expect(credentials.reads == 1)

        for _ in 0..<5 {
            clock.advance(minutes: 1)
            await poller.refreshOnActivation()
        }
        #expect(credentials.reads == 1)
        #expect(fetcher.tokens.count == 1)
        #expect(poller.needsSignIn)
    }

    @Test func activationRefreshesAreThrottled() async {
        let credentials = CountingCredentials("token-a")
        let poller = makePoller(credentials)
        fetcher.enqueue(.success(sample), .success(sample), .success(sample))

        await poller.refreshOnActivation()
        clock.now = clock.now.addingTimeInterval(10)
        await poller.refreshOnActivation()
        #expect(fetcher.tokens.count == 1)

        clock.now = clock.now.addingTimeInterval(PlanUsagePoller.activationInterval)
        await poller.refreshOnActivation()
        #expect(fetcher.tokens.count == 2)
        #expect(credentials.reads == 1)
    }

    @Test func retriesOnceWithARotatedToken() async {
        let credentials = CountingCredentials("token-a", "token-b")
        let poller = makePoller(credentials)
        fetcher.enqueue(.success(sample), .failure(.unauthorized), .success(sample))

        await poller.poll()
        await poller.poll()

        #expect(!poller.needsSignIn)
        #expect(poller.usage == sample)
        #expect(credentials.reads == 2)
        #expect(fetcher.tokens == ["token-a", "token-a", "token-b"])
    }

    @Test func missingCredentialsNeedSignInWithoutFetching() async {
        let credentials = CountingCredentials(nil)
        let poller = makePoller(credentials)

        await poller.poll()
        await poller.poll()

        #expect(poller.needsSignIn)
        #expect(credentials.reads == 1)
        #expect(fetcher.tokens.isEmpty)
    }

    @Test func startClearsTheSignInBlockAndStopEndsTheLoop() async throws {
        let credentials = CountingCredentials(nil)
        let poller = makePoller(credentials)
        await poller.poll()
        #expect(poller.needsSignIn)

        poller.start()
        #expect(poller.isRunning)
        #expect(!poller.needsSignIn)
        poller.stop()
        #expect(!poller.isRunning)
    }
}

struct PlanUsageDisplayTests {
    let usage = PlanUsage(
        session: PlanUsageWindow(utilization: 42.4, resetsAt: Date(timeIntervalSince1970: 1_793_225_400)),
        week: PlanUsageWindow(utilization: 18, resetsAt: Date(timeIntervalSince1970: 1_793_696_400))
    )

    @Test func isHiddenOutsideClaudeSignIn() {
        #expect(!PlanUsageDisplay.isVisible(mode: .apiKey, usage: usage, needsSignIn: false))
        #expect(!PlanUsageDisplay.isVisible(mode: .apiKey, usage: nil, needsSignIn: true))
        #expect(!PlanUsageDisplay.isVisible(mode: nil, usage: usage, needsSignIn: false))
        #expect(PlanUsageDisplay.isVisible(mode: .claudeSignIn, usage: usage, needsSignIn: false))
        #expect(PlanUsageDisplay.isVisible(mode: .claudeSignIn, usage: nil, needsSignIn: true))
        #expect(!PlanUsageDisplay.isVisible(mode: .claudeSignIn, usage: nil, needsSignIn: false))
        #expect(!PlanUsageDisplay.isVisible(mode: .claudeSignIn, usage: PlanUsage(), needsSignIn: false))
    }

    @Test func labelsBothWindowsAndOmitsMissingOnes() {
        #expect(PlanUsageDisplay.label(usage) == "Session 42% · Week 18%")
        #expect(PlanUsageDisplay.label(PlanUsage(week: PlanUsageWindow(utilization: 7))) == "Week 7%")
        #expect(PlanUsageDisplay.label(PlanUsage(session: PlanUsageWindow(utilization: 99.6))) == "Session 100%")
    }

    @Test func flagsHighUsage() {
        #expect(PlanUsageSeverity(percent: 79) == .normal)
        #expect(PlanUsageSeverity(percent: 80) == .warning)
        #expect(PlanUsageSeverity(percent: 99) == .warning)
        #expect(PlanUsageSeverity(percent: 100) == .danger)
        #expect(PlanUsageSeverity(percent: 130) == .danger)
        let segments = PlanUsageDisplay.segments(PlanUsage(session: PlanUsageWindow(utilization: 85), week: PlanUsageWindow(utilization: 100)))
        #expect(segments.map(\.severity) == [.warning, .danger])
    }

    @Test func helpGivesTheResetTimes() {
        let help = PlanUsageDisplay.help(usage, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(help == "Session resets 10:10 PM · Week resets Tue 9:00 AM")
        #expect(PlanUsageDisplay.help(PlanUsage(session: PlanUsageWindow(utilization: 1))) == "Claude plan usage")
    }
}
