import Foundation

public enum RiskTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case core
    case standard
    case low

    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct ReviewPolicy: Sendable, Hashable, Codable {
    public static let fileName = "review.yaml"

    public struct SizeGuard: Sendable, Hashable, Codable {
        public var maxLines: Int
        public var maxFiles: Int

        public init(maxLines: Int = 400, maxFiles: Int = 25) {
            self.maxLines = maxLines
            self.maxFiles = maxFiles
        }

        enum CodingKeys: String, CodingKey {
            case maxLines = "max_lines"
            case maxFiles = "max_files"
        }

        public init(from decoder: Decoder) throws {
            let defaults = SizeGuard()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.maxLines = try container.decodeIfPresent(Int.self, forKey: .maxLines) ?? defaults.maxLines
            self.maxFiles = try container.decodeIfPresent(Int.self, forKey: .maxFiles) ?? defaults.maxFiles
        }
    }

    public struct Gates: Sendable, Hashable, Codable {
        public var secrets: Bool
        public var dependencies: Bool
        public var maxDuplicateLines: Int
        public var maxComplexityIncrease: Int

        public init(secrets: Bool = true, dependencies: Bool = true, maxDuplicateLines: Int = 20, maxComplexityIncrease: Int = 25) {
            self.secrets = secrets
            self.dependencies = dependencies
            self.maxDuplicateLines = maxDuplicateLines
            self.maxComplexityIncrease = maxComplexityIncrease
        }

        enum CodingKeys: String, CodingKey {
            case secrets, dependencies
            case maxDuplicateLines = "max_duplicate_lines"
            case maxComplexityIncrease = "max_complexity_increase"
        }

        public init(from decoder: Decoder) throws {
            let defaults = Gates()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.secrets = try container.decodeIfPresent(Bool.self, forKey: .secrets) ?? defaults.secrets
            self.dependencies = try container.decodeIfPresent(Bool.self, forKey: .dependencies) ?? defaults.dependencies
            self.maxDuplicateLines = try container.decodeIfPresent(Int.self, forKey: .maxDuplicateLines) ?? defaults.maxDuplicateLines
            self.maxComplexityIncrease = try container.decodeIfPresent(Int.self, forKey: .maxComplexityIncrease) ?? defaults.maxComplexityIncrease
        }
    }

    public struct RiskTiers: Sendable, Hashable, Codable {
        public static let defaultCore = ["**/auth/**", "**/payments/**", "**/billing/**", "**/security/**", "**/migrations/**", ".github/workflows/**"]
        public static let defaultLow = ["docs/**", "*.md"]

        public var core: [String]
        public var low: [String]
        public var coreLabels: [String]

        public init(core: [String] = defaultCore, low: [String] = defaultLow, coreLabels: [String] = ["security"]) {
            self.core = core
            self.low = low
            self.coreLabels = coreLabels
        }

        enum CodingKeys: String, CodingKey {
            case core, low
            case coreLabels = "core_labels"
        }

        public init(from decoder: Decoder) throws {
            let defaults = RiskTiers()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.core = try container.decodeIfPresent([String].self, forKey: .core) ?? defaults.core
            self.low = try container.decodeIfPresent([String].self, forKey: .low) ?? defaults.low
            self.coreLabels = try container.decodeIfPresent([String].self, forKey: .coreLabels) ?? defaults.coreLabels
        }

        public func tier(of path: String, labels: [String] = []) -> RiskTier {
            let lowered = Set(labels.map { $0.lowercased() })
            if core.contains(where: { PathGlob($0).matches(path) }) || coreLabels.contains(where: { lowered.contains($0.lowercased()) }) {
                return .core
            }
            if low.contains(where: { PathGlob($0).matches(path) }) { return .low }
            return .standard
        }
    }

    public struct Reviewer: Sendable, Hashable, Codable {
        public var minConfidence: Double
        public var suppressedCategories: [String]
        public var fixRounds: Int

        public init(minConfidence: Double = 0.6, suppressedCategories: [String] = ["style", "nit"], fixRounds: Int = 1) {
            self.minConfidence = minConfidence
            self.suppressedCategories = suppressedCategories
            self.fixRounds = fixRounds
        }

        enum CodingKeys: String, CodingKey {
            case minConfidence = "min_confidence"
            case suppressedCategories = "suppressed_categories"
            case fixRounds = "fix_rounds"
        }

        public init(from decoder: Decoder) throws {
            let defaults = Reviewer()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.minConfidence = try container.decodeIfPresent(Double.self, forKey: .minConfidence) ?? defaults.minConfidence
            self.suppressedCategories = try container.decodeIfPresent([String].self, forKey: .suppressedCategories) ?? defaults.suppressedCategories
            self.fixRounds = try container.decodeIfPresent(Int.self, forKey: .fixRounds) ?? defaults.fixRounds
        }

        public func hides(confidence: Double?, category: String?) -> Bool {
            if let category, suppressedCategories.contains(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) { return true }
            if let confidence, confidence < minConfidence { return true }
            return false
        }
    }

    public struct Evidence: Sendable, Hashable, Codable {
        public static let defaultUIPaths = ["*.tsx", "*.jsx", "*.vue", "*.svelte", "*.css", "*.scss", "*.html", "*View.swift"]

        public var uiPaths: [String]
        public var performanceLabels: [String]

        public init(uiPaths: [String] = defaultUIPaths, performanceLabels: [String] = ["performance", "perf"]) {
            self.uiPaths = uiPaths
            self.performanceLabels = performanceLabels
        }

        enum CodingKeys: String, CodingKey {
            case uiPaths = "ui_paths"
            case performanceLabels = "performance_labels"
        }

        public init(from decoder: Decoder) throws {
            let defaults = Evidence()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.uiPaths = try container.decodeIfPresent([String].self, forKey: .uiPaths) ?? defaults.uiPaths
            self.performanceLabels = try container.decodeIfPresent([String].self, forKey: .performanceLabels) ?? defaults.performanceLabels
        }
    }

    public var sizeGuard: SizeGuard
    public var gates: Gates
    public var riskTiers: RiskTiers
    public var reviewer: Reviewer
    public var evidence: Evidence

    public init(sizeGuard: SizeGuard = SizeGuard(), gates: Gates = Gates(), riskTiers: RiskTiers = RiskTiers(), reviewer: Reviewer = Reviewer(), evidence: Evidence = Evidence()) {
        self.sizeGuard = sizeGuard
        self.gates = gates
        self.riskTiers = riskTiers
        self.reviewer = reviewer
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case gates, reviewer, evidence
        case sizeGuard = "size_guard"
        case riskTiers = "risk_tiers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sizeGuard = try container.decodeIfPresent(SizeGuard.self, forKey: .sizeGuard) ?? SizeGuard()
        self.gates = try container.decodeIfPresent(Gates.self, forKey: .gates) ?? Gates()
        self.riskTiers = try container.decodeIfPresent(RiskTiers.self, forKey: .riskTiers) ?? RiskTiers()
        self.reviewer = try container.decodeIfPresent(Reviewer.self, forKey: .reviewer) ?? Reviewer()
        self.evidence = try container.decodeIfPresent(Evidence.self, forKey: .evidence) ?? Evidence()
    }

    public static func file(in repository: URL) -> URL {
        ProjectConfig.directory(in: repository).appending(path: fileName)
    }

    static func validate(_ policy: ReviewPolicy) -> [String] {
        var problems: [String] = []
        if policy.sizeGuard.maxLines < 1 || policy.sizeGuard.maxFiles < 1 {
            problems.append("size_guard: max_lines and max_files must be at least 1")
        }
        if !(0...1).contains(policy.reviewer.minConfidence) {
            problems.append("reviewer.min_confidence must be between 0 and 1")
        }
        if policy.reviewer.fixRounds < 0 {
            problems.append("reviewer.fix_rounds can’t be negative")
        }
        return problems
    }
}
