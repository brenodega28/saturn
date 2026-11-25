import Foundation

public struct PlanUsageWindow: Sendable, Hashable {
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct PlanUsage: Sendable, Hashable {
    public var session: PlanUsageWindow?
    public var week: PlanUsageWindow?

    public init(session: PlanUsageWindow? = nil, week: PlanUsageWindow? = nil) {
        self.session = session
        self.week = week
    }

    public var isEmpty: Bool { session == nil && week == nil }

    public static func parse(_ data: Data) throws -> PlanUsage {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PlanUsageError.failed("Claude returned usage data Ensemble could not read.")
        }
        return PlanUsage(session: response.fiveHour?.window, week: response.sevenDay?.window)
    }

    static func date(fromISO8601 text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let withoutFraction = trimmed.replacing(/\.\d+(?=(Z|z|[+-]\d{2}:?\d{2})?$)/, with: "")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: withoutFraction)
    }

    private struct Response: Decodable {
        var fiveHour: RawWindow?
        var sevenDay: RawWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct RawWindow: Decodable {
        var utilization: Double?
        var resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var window: PlanUsageWindow? {
            utilization.map { PlanUsageWindow(utilization: $0, resetsAt: resetsAt.flatMap(PlanUsage.date(fromISO8601:))) }
        }
    }
}

public enum PlanUsageError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case rateLimited(resetAt: Date?)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Claude rejected the sign-in. Sign in to Claude Code again."
        case .rateLimited(let resetAt):
            if let resetAt {
                "Claude usage checks are rate limited until \(resetAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "Claude usage checks are rate limited. Try again shortly."
            }
        case .failed(let message):
            message
        }
    }
}

public enum PlanUsageSeverity: Sendable, Hashable {
    case normal
    case warning
    case danger

    public init(percent: Int) {
        if percent >= 100 {
            self = .danger
        } else if percent >= 80 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

public enum PlanUsageDisplay {
    public struct Segment: Sendable, Hashable, Identifiable {
        public var title: String
        public var percent: Int
        public var severity: PlanUsageSeverity

        public var id: String { title }
        public var text: String { "\(title) \(percent)%" }
    }

    public static func isVisible(mode: ProviderMode?, usage: PlanUsage?, needsSignIn: Bool) -> Bool {
        guard mode == .claudeSignIn else { return false }
        return needsSignIn || usage.map { !$0.isEmpty } ?? false
    }

    public static func percent(_ utilization: Double) -> Int {
        guard utilization.isFinite else { return 0 }
        return max(Int(utilization.rounded()), 0)
    }

    public static func segments(_ usage: PlanUsage) -> [Segment] {
        [("Session", usage.session), ("Week", usage.week)].compactMap { title, window in
            window.map {
                let percent = percent($0.utilization)
                return Segment(title: title, percent: percent, severity: PlanUsageSeverity(percent: percent))
            }
        }
    }

    public static func label(_ usage: PlanUsage) -> String {
        segments(usage).map(\.text).joined(separator: " · ")
    }

    public static func help(_ usage: PlanUsage, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let sessionStyle = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        let weekStyle = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).hour().minute()
        let parts = [
            usage.session?.resetsAt.map { "Session resets \($0.formatted(sessionStyle))" },
            usage.week?.resetsAt.map { "Week resets \($0.formatted(weekStyle))" },
        ].compactMap(\.self)
        return parts.isEmpty ? "Claude plan usage" : parts.joined(separator: " · ")
    }
}
