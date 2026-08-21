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
        case .claude: "Writing, analysis, and research"
        case .codex: "Engineering and code workflows"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "terminal"
        }
    }

    var accountCapabilities: AIProviderAccountCapabilities {
        switch self {
        case .codex:
            AIProviderAccountCapabilities(
                credentialScope: .accountDirectory,
                configurationScope: .accountDirectory,
                operationScope: .account,
                maximumTrackedAccounts: nil
            )
        case .claude:
            AIProviderAccountCapabilities(
                credentialScope: .macOSUserShared,
                configurationScope: .macOSUserShared,
                operationScope: .provider,
                maximumTrackedAccounts: 1
            )
        }
    }
}

/// Where the provider stores the credential that determines the signed-in
/// principal. A provider can keep account-specific configuration while still
/// sharing one credential for the current macOS user.
enum AIProviderCredentialScope: Equatable, Sendable {
    case accountDirectory
    case macOSUserShared
}

/// Where provider configuration used by Control Center is read from.
enum AIProviderConfigurationScope: Equatable, Sendable {
    case accountDirectory
    case macOSUserShared
}

/// The narrowest safe serialization boundary for sign-in and refresh work.
enum AIProviderAccountOperationScope: Equatable, Sendable {
    case account
    case provider
}

struct AIProviderAccountCapabilities: Equatable, Sendable {
    let credentialScope: AIProviderCredentialScope
    let configurationScope: AIProviderConfigurationScope
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
            "The provider requires sign-in before status can refresh."
        case .providerToolUnavailable:
            "The trusted provider tool is unavailable."
        case .signInFailed:
            "Provider sign-in did not complete."
        case .statusUnavailable:
            "Provider status could not be refreshed."
        case .incompleteProviderData:
            "The provider response did not include current usage."
        case .interrupted:
            "The previous refresh did not finish."
        }
    }
}

enum TrackedAccountAttemptKind: String, Codable, Equatable, Sendable {
    case signIn
    case refresh
}

enum AIUsageWindowKind: String, Codable, Equatable, Sendable {
    case session
    case weeklyAllModels
    case weeklyModel
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

    static func state(
        for account: TrackedAIAccount,
        now: Date,
        ageThreshold: TimeInterval = currentAgeThreshold
    ) -> CorporateAccountFreshnessState {
        let success = account.lastSuccessfulRefreshAt
        let attempt = account.lastRefreshAttemptAt
        let completion = account.lastRefreshCompletedAt

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
    var lastSuccessfulRefreshAt: Date?
    var lastRefreshAttemptAt: Date?
    var lastRefreshCompletedAt: Date?
    var lastAttemptKind: TrackedAccountAttemptKind?
    var lastRefreshFailure: TrackedAccountRefreshFailure?
    var isConnected: Bool?
    var lifetimeTokens: Int?
    var usageWindows: [AIUsageWindow]

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
        usageWindows: [AIUsageWindow] = []
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.planName = planName
        self.usagePercent = usagePercent
        self.resetsAt = resetsAt
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
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case email
        case planName
        case usagePercent
        case resetsAt
        case lastCheckedAt
        case lastSuccessfulRefreshAt
        case lastRefreshAttemptAt
        case lastRefreshCompletedAt
        case lastAttemptKind
        case lastRefreshFailure
        case isConnected
        case lifetimeTokens
        case usageWindows
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
            lastAttemptKind = try container.decodeIfPresent(
                TrackedAccountAttemptKind.self,
                forKey: .lastAttemptKind
            )
            lastRefreshFailure = try container.decodeIfPresent(
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
            [AIUsageWindow].self,
            forKey: .usageWindows
        ) ?? []
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
    }

    var normalizedUsagePercent: Int {
        if provider == .claude,
            let maximum = usageWindows.map(\.normalizedUsagePercent).max()
        {
            return maximum
        }
        return min(max(usagePercent, 0), 100)
    }

    var needsAttention: Bool {
        normalizedUsagePercent >= 85
    }
}
