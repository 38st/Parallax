import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var shortDescription: String {
        switch self {
        case .claude: String(localized: "Writing, analysis, and research")
        case .codex: String(localized: "Engineering and code workflows")
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "terminal"
        }
    }

    /// Both providers bind credentials and configuration to the tracked
    /// account's own directory, so every account is an independent
    /// operation scope with no cap on how many can be tracked.
    var accountCapabilities: AIProviderAccountCapabilities {
        AIProviderAccountCapabilities(
            operationScope: .account,
            maximumTrackedAccounts: nil
        )
    }
}

/// The narrowest safe serialization boundary for sign-in and refresh work.
enum AIProviderAccountOperationScope: Equatable, Sendable {
    case account
    case provider
}

struct AIProviderAccountCapabilities: Equatable, Sendable {
    let operationScope: AIProviderAccountOperationScope
    let maximumTrackedAccounts: Int?

    func canAddAccount(to existingCount: Int) -> Bool {
        guard let maximumTrackedAccounts else { return true }
        return existingCount < maximumTrackedAccounts
    }
}

enum TrackedAccountRefreshFailure: String, Codable, Equatable, Sendable {
    case authenticationRequired
    case providerToolUnavailable
    case signInFailed
    case statusUnavailable
    case incompleteProviderData
    case interrupted

    var userMessage: String {
        switch self {
        case .authenticationRequired:
            String(
                localized:
                    "The provider requires sign-in before status can refresh."
            )
        case .providerToolUnavailable:
            String(localized: "The trusted provider tool is unavailable.")
        case .signInFailed:
            String(localized: "Provider sign-in did not complete.")
        case .statusUnavailable:
            String(localized: "Provider status could not be refreshed.")
        case .incompleteProviderData:
            String(
                localized:
                    "The provider response did not include current usage."
            )
        case .interrupted:
            String(localized: "The previous refresh did not finish.")
        }
    }
}

enum TrackedAccountAttemptKind: String, Codable, Equatable, Sendable {
    case signIn
    case refresh
}

enum AIUsageWindowKind: String, Codable, Equatable, Sendable, Hashable {
    case session
    case weeklyAllModels
    case weeklyModel

    /// Display order shared by every provider parser: the short window
    /// first, then the weekly windows.
    var sortOrder: Int {
        switch self {
        case .session: 0
        case .weeklyAllModels: 1
        case .weeklyModel: 2
        }
    }
}

extension Array where Element == AIUsageWindow {
    /// The window that determines the headline percentage and reset time:
    /// the most exhausted one. Every consumer derives the headline from this
    /// single rule so the percentage and its reset time always belong to the
    /// same window.
    var mostExhausted: AIUsageWindow? {
        self.max { $0.normalizedUsagePercent < $1.normalizedUsagePercent }
    }
}

struct AIUsageWindow: Codable, Equatable, Sendable {
    let kind: AIUsageWindowKind
    let modelName: String?
    let usagePercent: Int
    let resetsAt: Date?

    init(
        kind: AIUsageWindowKind,
        modelName: String? = nil,
        usagePercent: Int,
        resetsAt: Date? = nil
    ) {
        self.kind = kind
        self.modelName = modelName
        self.usagePercent = usagePercent
        self.resetsAt = resetsAt
    }

    var normalizedUsagePercent: Int {
        min(max(usagePercent, 0), 100)
    }

    /// Stable identity for view diffing: the same window keeps its identity
    /// across refreshes even when the provider reorders lines or a model
    /// window appears or disappears.
    var identity: String {
        kind.rawValue + ":" + (modelName?.lowercased() ?? "")
    }
}

/// Decodes an array element by element, dropping entries a newer build wrote
/// in a shape this build does not understand instead of failing the whole
/// record.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(AnyDecodable.self)
            }
        }
        self.elements = elements
    }
}

enum CorporateAccountStaleReason: Equatable, Sendable {
    case ageExpired
    case clockAnomaly
}

enum CorporateAccountFreshnessState: Equatable, Sendable {
    case neverRefreshed
    case current(lastSuccessfulRefreshAt: Date)
    case stale(lastSuccessfulRefreshAt: Date, reason: CorporateAccountStaleReason)
    case failed(
        lastSuccessfulRefreshAt: Date?,
        attemptedAt: Date?,
        failure: TrackedAccountRefreshFailure
    )
    /// An operation is running and the previous values are no longer
    /// current. Distinct from `.failed(.interrupted)`, which is what the same
    /// persisted record means once no operation is alive.
    case refreshing(
        kind: TrackedAccountAttemptKind,
        lastSuccessfulRefreshAt: Date?
    )

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}

enum CorporateAccountFreshnessPolicy {
    /// Provider values are current for 15 minutes after a successful refresh.
    /// Future timestamps fail closed because wall-clock rollback makes their
    /// age unverifiable.
    static let currentAgeThreshold: TimeInterval = 15 * 60

    /// - Parameter inFlightAttemptKind: The kind of operation currently
    ///   running for this account, if any. The persisted record deliberately
    ///   looks interrupted while an operation runs (so a crash is never
    ///   mistaken for success); this parameter lets every presentation tell
    ///   the two apart and keep still-current values on screen.
    static func state(
        for account: TrackedAIAccount,
        now: Date,
        ageThreshold: TimeInterval = currentAgeThreshold,
        inFlightAttemptKind: TrackedAccountAttemptKind? = nil
    ) -> CorporateAccountFreshnessState {
        let success = account.lastSuccessfulRefreshAt
        let attempt = account.lastRefreshAttemptAt
        let completion = account.lastRefreshCompletedAt

        if let inFlightAttemptKind {
            if let success,
                success <= now,
                now.timeIntervalSince(success) <= max(ageThreshold, 0)
            {
                return .current(lastSuccessfulRefreshAt: success)
            }
            return .refreshing(
                kind: inFlightAttemptKind,
                lastSuccessfulRefreshAt: success
            )
        }

        if let failure = account.lastRefreshFailure {
            return .failed(
                lastSuccessfulRefreshAt: success,
                attemptedAt: attempt,
                failure: failure
            )
        }

        if attempt != nil, completion == nil {
            return .failed(
                lastSuccessfulRefreshAt: success,
                attemptedAt: attempt,
                failure: .interrupted
            )
        }

        guard let success else {
            if attempt != nil {
                return .failed(
                    lastSuccessfulRefreshAt: nil,
                    attemptedAt: attempt,
                    failure: .interrupted
                )
            }
            return .neverRefreshed
        }

        if success > now
            || (attempt.map { $0 > now } ?? false)
            || (completion.map { $0 > now } ?? false)
        {
            return .stale(
                lastSuccessfulRefreshAt: success,
                reason: .clockAnomaly
            )
        }

        if let attempt, attempt > success {
            return .failed(
                lastSuccessfulRefreshAt: success,
                attemptedAt: attempt,
                failure: .interrupted
            )
        }

        if now.timeIntervalSince(success) > max(ageThreshold, 0) {
            return .stale(
                lastSuccessfulRefreshAt: success,
                reason: .ageExpired
            )
        }

        return .current(lastSuccessfulRefreshAt: success)
    }
}

struct TrackedAIAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var provider: AIProvider
    var label: String
    var email: String
    var planName: String
    var usagePercent: Int
    var resetsAt: Date
    var providerResetsAt: Date?
    var lastSuccessfulRefreshAt: Date?
    var lastRefreshAttemptAt: Date?
    var lastRefreshCompletedAt: Date?
    var lastAttemptKind: TrackedAccountAttemptKind?
    var lastRefreshFailure: TrackedAccountRefreshFailure?
    var isConnected: Bool?
    var lifetimeTokens: Int?
    var usageWindows: [AIUsageWindow]
    /// Set when the provider explicitly reported no login for this account's
    /// directory. Unlike `lastRefreshFailure`, which only describes the most
    /// recent attempt, this survives later transient failures and a failed
    /// browser sign-in; only a successful refresh or sign-in clears it.
    var signInRequired: Bool?

    /// Compatibility alias for callers and persisted v1 records that used one
    /// timestamp for both an attempt and a successful refresh.
    var lastCheckedAt: Date? {
        get { lastSuccessfulRefreshAt }
        set {
            lastSuccessfulRefreshAt = newValue
            if let newValue {
                lastRefreshAttemptAt = newValue
                lastRefreshCompletedAt = newValue
                lastAttemptKind = .refresh
                lastRefreshFailure = nil
            } else {
                lastRefreshAttemptAt = nil
                lastRefreshCompletedAt = nil
                lastAttemptKind = nil
                lastRefreshFailure = nil
            }
        }
    }

    init(
        id: UUID,
        provider: AIProvider,
        label: String,
        email: String,
        planName: String,
        usagePercent: Int,
        resetsAt: Date,
        lastCheckedAt: Date?,
        isConnected: Bool?,
        lifetimeTokens: Int?,
        lastSuccessfulRefreshAt: Date? = nil,
        lastRefreshAttemptAt: Date? = nil,
        lastRefreshCompletedAt: Date? = nil,
        lastAttemptKind: TrackedAccountAttemptKind? = nil,
        lastRefreshFailure: TrackedAccountRefreshFailure? = nil,
        usageWindows: [AIUsageWindow] = [],
        providerResetsAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.planName = planName
        self.usagePercent = usagePercent
        self.resetsAt = resetsAt
        self.providerResetsAt = providerResetsAt
        let hasExplicitFreshnessLifecycle =
            lastSuccessfulRefreshAt != nil
            || lastRefreshAttemptAt != nil
            || lastRefreshCompletedAt != nil
            || lastAttemptKind != nil
            || lastRefreshFailure != nil
        if hasExplicitFreshnessLifecycle {
            self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
            self.lastRefreshAttemptAt = lastRefreshAttemptAt
            self.lastRefreshCompletedAt = lastRefreshCompletedAt
            self.lastAttemptKind = lastAttemptKind
        } else {
            self.lastSuccessfulRefreshAt = lastCheckedAt
            self.lastRefreshAttemptAt = lastCheckedAt
            self.lastRefreshCompletedAt = lastCheckedAt
            self.lastAttemptKind = lastCheckedAt == nil ? nil : .refresh
        }
        self.lastRefreshFailure = lastRefreshFailure
        self.isConnected = isConnected
        self.lifetimeTokens = lifetimeTokens
        self.usageWindows = usageWindows
        self.signInRequired = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case email
        case planName
        case usagePercent
        case resetsAt
        case providerResetsAt
        case lastCheckedAt
        case lastSuccessfulRefreshAt
        case lastRefreshAttemptAt
        case lastRefreshCompletedAt
        case lastAttemptKind
        case lastRefreshFailure
        case isConnected
        case lifetimeTokens
        case usageWindows
        case signInRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        label = try container.decode(String.self, forKey: .label)
        email = try container.decode(String.self, forKey: .email)
        planName = try container.decode(String.self, forKey: .planName)
        usagePercent = try container.decode(Int.self, forKey: .usagePercent)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
        providerResetsAt = try container.decodeIfPresent(
            Date.self,
            forKey: .providerResetsAt
        )
        let legacyCheckedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastCheckedAt
        )
        let hasNewFreshnessKeys = [
            CodingKeys.lastSuccessfulRefreshAt,
            .lastRefreshAttemptAt,
            .lastRefreshCompletedAt,
            .lastAttemptKind,
            .lastRefreshFailure,
        ].contains(where: container.contains)
        if hasNewFreshnessKeys {
            lastSuccessfulRefreshAt = try container.decodeIfPresent(
                Date.self,
                forKey: .lastSuccessfulRefreshAt
            )
            lastRefreshAttemptAt = try container.decodeIfPresent(
                Date.self,
                forKey: .lastRefreshAttemptAt
            )
            lastRefreshCompletedAt = try container.decodeIfPresent(
                Date.self,
                forKey: .lastRefreshCompletedAt
            )
            // Enum values introduced by a newer build must not make the
            // whole account inventory undecodable; treat them as unknown and
            // let the next refresh re-establish state.
            lastAttemptKind = try? container.decodeIfPresent(
                TrackedAccountAttemptKind.self,
                forKey: .lastAttemptKind
            )
            lastRefreshFailure = try? container.decodeIfPresent(
                TrackedAccountRefreshFailure.self,
                forKey: .lastRefreshFailure
            )
        } else {
            lastSuccessfulRefreshAt = legacyCheckedAt
            lastRefreshAttemptAt = legacyCheckedAt
            lastRefreshCompletedAt = legacyCheckedAt
            lastAttemptKind = legacyCheckedAt == nil ? nil : .refresh
            lastRefreshFailure = nil
        }
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected)
        lifetimeTokens = try container.decodeIfPresent(Int.self, forKey: .lifetimeTokens)
        usageWindows = try container.decodeIfPresent(
            LossyDecodableArray<AIUsageWindow>.self,
            forKey: .usageWindows
        )?.elements ?? []
        signInRequired = try container.decodeIfPresent(
            Bool.self,
            forKey: .signInRequired
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encode(email, forKey: .email)
        try container.encode(planName, forKey: .planName)
        try container.encode(usagePercent, forKey: .usagePercent)
        try container.encode(resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(
            providerResetsAt,
            forKey: .providerResetsAt
        )
        try container.encodeIfPresent(
            lastSuccessfulRefreshAt,
            forKey: .lastCheckedAt
        )
        try container.encodeIfPresent(
            lastSuccessfulRefreshAt,
            forKey: .lastSuccessfulRefreshAt
        )
        try container.encodeIfPresent(
            lastRefreshAttemptAt,
            forKey: .lastRefreshAttemptAt
        )
        try container.encodeIfPresent(
            lastRefreshCompletedAt,
            forKey: .lastRefreshCompletedAt
        )
        try container.encodeIfPresent(lastAttemptKind, forKey: .lastAttemptKind)
        try container.encodeIfPresent(
            lastRefreshFailure,
            forKey: .lastRefreshFailure
        )
        try container.encodeIfPresent(isConnected, forKey: .isConnected)
        try container.encodeIfPresent(lifetimeTokens, forKey: .lifetimeTokens)
        if !usageWindows.isEmpty {
            try container.encode(usageWindows, forKey: .usageWindows)
        }
        try container.encodeIfPresent(signInRequired, forKey: .signInRequired)
    }

    /// The headline percentage is the most exhausted provider window when
    /// windows are known; the flat value is a fallback for records without
    /// them (older Codex reads and user-entered fallbacks).
    var normalizedUsagePercent: Int {
        if let window = usageWindows.mostExhausted {
            return window.normalizedUsagePercent
        }
        return min(max(usagePercent, 0), 100)
    }

    var needsAttention: Bool {
        normalizedUsagePercent >= 85
    }

    /// The provider explicitly reported no login for this account's
    /// directory, and nothing has succeeded since. The account stays
    /// connected so the automatic pass keeps verifying it; the card offers
    /// "Sign in" until a refresh or sign-in succeeds.
    var needsSignIn: Bool {
        signInRequired == true || lastRefreshFailure == .authenticationRequired
    }

    /// Connected and not waiting on a provider sign-in. "Connected" counts
    /// use this; the refresh pass uses `isConnected` alone so accounts that
    /// need sign-in keep being verified.
    var isSignedIn: Bool {
        isConnected == true && !needsSignIn
    }
}
