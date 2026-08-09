import Foundation
import Observation

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
}

struct CorporateSeatUsage: Codable, Equatable, Sendable {
    var allocatedCapacity: Int
    var consumedCapacity: Int

    var utilization: Double {
        guard allocatedCapacity > 0 else { return 0 }
        return min(Double(consumedCapacity) / Double(allocatedCapacity), 1.5)
    }

    var reclaimableCapacity: Int {
        max(allocatedCapacity - consumedCapacity - 10, 0)
    }

    var isAtRisk: Bool {
        allocatedCapacity > 0 && utilization >= 0.85
    }
}

struct CorporateMember: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var email: String
    var team: String
    var role: String
    var claude: CorporateSeatUsage
    var codex: CorporateSeatUsage

    func usage(for provider: AIProvider) -> CorporateSeatUsage {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    mutating func setUsage(
        _ usage: CorporateSeatUsage,
        for provider: AIProvider
    ) {
        switch provider {
        case .claude: claude = usage
        case .codex: codex = usage
        }
    }
}

struct CorporateProviderPool: Identifiable, Codable, Equatable, Sendable {
    var id: AIProvider { provider }
    let provider: AIProvider
    var purchasedSeats: Int
    var assignedSeats: Int
    var capacityUsedPercent: Int

    var reserveSeats: Int {
        max(purchasedSeats - assignedSeats, 0)
    }
}

struct CapacityTransfer: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let provider: AIProvider
    let sourceMemberID: UUID
    let sourceName: String
    let destinationMemberID: UUID
    let destinationName: String
    let capacity: Int
    let createdAt: Date
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
            "The provider response did not include current Codex usage."
        case .interrupted:
            "The previous refresh did not finish."
        }
    }
}

enum TrackedAccountAttemptKind: String, Codable, Equatable, Sendable {
    case signIn
    case refresh
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
        lastRefreshFailure: TrackedAccountRefreshFailure? = nil
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
    }

    var normalizedUsagePercent: Int {
        min(max(usagePercent, 0), 100)
    }

    var needsAttention: Bool {
        normalizedUsagePercent >= 85
    }
}

struct CorporateWorkspaceSnapshot: Codable, Equatable, Sendable {
    var organizationName: String
    var cycleEndsAt: Date
    var autoRebalanceEnabled: Bool
    var providerPools: [CorporateProviderPool]
    var members: [CorporateMember]
    var transfers: [CapacityTransfer]
    var trackedAccounts: [TrackedAIAccount]?
}

enum CapacityTransferError: LocalizedError, Equatable {
    case sameMember
    case invalidAmount
    case memberNotFound
    case insufficientCapacity(available: Int)

    var errorDescription: String? {
        switch self {
        case .sameMember:
            "Choose two different people."
        case .invalidAmount:
            "Capacity must be greater than zero."
        case .memberNotFound:
            "One of the selected people is no longer available."
        case let .insufficientCapacity(available):
            "Only \(available) capacity points are currently reclaimable."
        }
    }
}

@MainActor
protocol CorporateFreshnessScheduling: AnyObject {
    func schedule(_ invalidate: @escaping @MainActor () -> Void)
}

private final class CorporateFreshnessTimerToken: @unchecked Sendable {
    let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    deinit {
        timer.invalidate()
    }
}

@MainActor
final class CorporateTimerFreshnessScheduler: CorporateFreshnessScheduling {
    private var token: CorporateFreshnessTimerToken?

    func schedule(_ invalidate: @escaping @MainActor () -> Void) {
        token = nil
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        token = CorporateFreshnessTimerToken(timer: timer)
    }
}

@MainActor
@Observable
final class CorporateUsageStore {
    private(set) var snapshot: CorporateWorkspaceSnapshot
    private let userDefaults: UserDefaults
    private let persistenceKey: String
    private let clock: () -> Date
    private let freshnessScheduler: any CorporateFreshnessScheduling
    private var accountOperationGenerations: [UUID: UUID] = [:]
    private(set) var freshnessRevision = 0

    var organizationName: String { snapshot.organizationName }
    var cycleEndsAt: Date { snapshot.cycleEndsAt }
    var providerPools: [CorporateProviderPool] { snapshot.providerPools }
    var members: [CorporateMember] { snapshot.members }
    var transfers: [CapacityTransfer] { snapshot.transfers }
    var autoRebalanceEnabled: Bool { snapshot.autoRebalanceEnabled }
    var trackedAccounts: [TrackedAIAccount] {
        snapshot.trackedAccounts ?? Self.defaultTrackedAccounts
    }
    var currentDate: Date {
        _ = freshnessRevision
        return clock()
    }

    init(
        userDefaults: UserDefaults = .standard,
        persistenceKey: String = "corporate.workspace.v1",
        initialSnapshot: CorporateWorkspaceSnapshot? = nil,
        clock: @escaping () -> Date = Date.init,
        freshnessScheduler: any CorporateFreshnessScheduling =
            CorporateTimerFreshnessScheduler()
    ) {
        self.userDefaults = userDefaults
        self.persistenceKey = persistenceKey
        self.clock = clock
        self.freshnessScheduler = freshnessScheduler

        if let initialSnapshot {
            snapshot = initialSnapshot
        } else if
            let data = userDefaults.data(forKey: persistenceKey),
            let decoded = try? JSONDecoder().decode(
                CorporateWorkspaceSnapshot.self,
                from: data
            )
        {
            snapshot = decoded
        } else {
            snapshot = Self.demoSnapshot
        }

        freshnessScheduler.schedule { [weak self] in
            self?.freshnessRevision &+= 1
        }
    }

    func pool(for provider: AIProvider) -> CorporateProviderPool {
        snapshot.providerPools.first(where: { $0.provider == provider })
            ?? CorporateProviderPool(
                provider: provider,
                purchasedSeats: 0,
                assignedSeats: 0,
                capacityUsedPercent: 0
            )
    }

    func usage(
        for memberID: UUID,
        provider: AIProvider
    ) -> CorporateSeatUsage? {
        snapshot.members.first(where: { $0.id == memberID })?
            .usage(for: provider)
    }

    func reclaimableMembers(for provider: AIProvider) -> [CorporateMember] {
        snapshot.members
            .filter { $0.usage(for: provider).reclaimableCapacity > 0 }
            .sorted {
                $0.usage(for: provider).reclaimableCapacity
                    > $1.usage(for: provider).reclaimableCapacity
            }
    }

    func atRiskMembers(for provider: AIProvider) -> [CorporateMember] {
        snapshot.members
            .filter { $0.usage(for: provider).isAtRisk }
            .sorted {
                $0.usage(for: provider).utilization
                    > $1.usage(for: provider).utilization
            }
    }

    var totalReclaimableCapacity: Int {
        AIProvider.allCases.reduce(0) { providerTotal, provider in
            providerTotal + snapshot.members.reduce(0) { memberTotal, member in
                memberTotal + member.usage(for: provider).reclaimableCapacity
            }
        }
    }

    var membersAtRiskCount: Int {
        Set(
            AIProvider.allCases.flatMap { provider in
                atRiskMembers(for: provider).map(\.id)
            }
        ).count
    }

    func setAutoRebalanceEnabled(_ enabled: Bool) {
        snapshot.autoRebalanceEnabled = enabled
        persist()
    }

    func saveTrackedAccount(_ account: TrackedAIAccount) {
        accountOperationGenerations.removeValue(forKey: account.id)
        upsertTrackedAccount(account)
    }

    private func upsertTrackedAccount(_ account: TrackedAIAccount) {
        var accounts = trackedAccounts
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        snapshot.trackedAccounts = accounts.sorted {
            if $0.provider != $1.provider {
                return $0.provider.rawValue > $1.provider.rawValue
            }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        persist()
    }

    @discardableResult
    func recordRefreshSuccess(
        _ account: TrackedAIAccount,
        operationGeneration: UUID
    ) -> Bool {
        guard let current = consumeOperation(
            accountID: account.id,
            generation: operationGeneration
        ) else { return false }
        var updated = account
        let refreshedAt = currentDate
        updated.lastRefreshAttemptAt = current.lastRefreshAttemptAt
        updated.lastAttemptKind = current.lastAttemptKind
        updated.lastSuccessfulRefreshAt = refreshedAt
        updated.lastRefreshCompletedAt = refreshedAt
        updated.lastRefreshFailure = nil
        upsertTrackedAccount(updated)
        return true
    }

    @discardableResult
    func recordRefreshAttempt(
        accountID: UUID,
        kind: TrackedAccountAttemptKind
    ) -> UUID? {
        guard var account = trackedAccounts.first(where: { $0.id == accountID })
        else { return nil }
        let generation = UUID()
        account.lastRefreshAttemptAt = currentDate
        account.lastRefreshCompletedAt = nil
        account.lastAttemptKind = kind
        account.lastRefreshFailure = nil
        // Persist the interrupted-attempt evidence before the caller invokes
        // the provider. A crash or cancellation after this return therefore
        // cannot look like a completed refresh after restart.
        upsertTrackedAccount(account)
        accountOperationGenerations[accountID] = generation
        return generation
    }

    func isCurrentOperation(
        accountID: UUID,
        generation: UUID
    ) -> Bool {
        accountOperationGenerations[accountID] == generation
            && trackedAccounts.contains(where: { $0.id == accountID })
    }

    @discardableResult
    func recordRefreshFailure(
        accountID: UUID,
        operationGeneration: UUID,
        failure: TrackedAccountRefreshFailure,
        disconnect: Bool = false
    ) -> Bool {
        guard let current = consumeOperation(
            accountID: accountID,
            generation: operationGeneration
        ) else { return false }
        var account = current
        let completedAt = currentDate
        account.lastRefreshAttemptAt = account.lastRefreshAttemptAt
            ?? completedAt
        account.lastRefreshCompletedAt = completedAt
        account.lastRefreshFailure = failure
        if disconnect { account.isConnected = false }
        upsertTrackedAccount(account)
        return true
    }

    @discardableResult
    func recordRefreshFailure(
        _ account: TrackedAIAccount,
        operationGeneration: UUID,
        failure: TrackedAccountRefreshFailure,
        disconnect: Bool = false
    ) -> Bool {
        guard let current = consumeOperation(
            accountID: account.id,
            generation: operationGeneration
        ) else { return false }
        var updated = account
        let completedAt = currentDate
        updated.lastRefreshAttemptAt = current.lastRefreshAttemptAt
            ?? completedAt
        updated.lastAttemptKind = current.lastAttemptKind
        updated.lastRefreshCompletedAt = completedAt
        updated.lastRefreshFailure = failure
        if disconnect { updated.isConnected = false }
        upsertTrackedAccount(updated)
        return true
    }

    private func consumeOperation(
        accountID: UUID,
        generation: UUID
    ) -> TrackedAIAccount? {
        guard
            let account = trackedAccounts.first(where: { $0.id == accountID }),
            accountOperationGenerations[accountID] == generation
        else { return nil }
        accountOperationGenerations.removeValue(forKey: accountID)
        return account
    }

    @discardableResult
    func addTrackedAccount(provider: AIProvider) -> TrackedAIAccount {
        let existingLabels = Set(
            trackedAccounts
                .filter { $0.provider == provider }
                .map(\.label)
        )
        var accountNumber = 1
        while existingLabels.contains(
            "\(provider.displayName) Account \(accountNumber)"
        ) {
            accountNumber += 1
        }

        let account = TrackedAIAccount(
            id: UUID(),
            provider: provider,
            label: "\(provider.displayName) Account \(accountNumber)",
            email: "",
            planName: "Subscription",
            usagePercent: 0,
            resetsAt: Calendar.current.date(
                byAdding: .month,
                value: 1,
                to: Date()
            ) ?? Date(),
            lastCheckedAt: nil,
            isConnected: false,
            lifetimeTokens: nil
        )
        saveTrackedAccount(account)
        return account
    }

    func removeTrackedAccount(id: UUID) {
        accountOperationGenerations.removeValue(forKey: id)
        snapshot.trackedAccounts = trackedAccounts.filter { $0.id != id }
        persist()
    }

    func transferCapacity(
        provider: AIProvider,
        from sourceMemberID: UUID,
        to destinationMemberID: UUID,
        capacity: Int,
        createdAt: Date = Date()
    ) throws {
        guard sourceMemberID != destinationMemberID else {
            throw CapacityTransferError.sameMember
        }
        guard capacity > 0 else {
            throw CapacityTransferError.invalidAmount
        }
        guard
            let sourceIndex = snapshot.members.firstIndex(where: {
                $0.id == sourceMemberID
            }),
            let destinationIndex = snapshot.members.firstIndex(where: {
                $0.id == destinationMemberID
            })
        else {
            throw CapacityTransferError.memberNotFound
        }

        let sourceMember = snapshot.members[sourceIndex]
        let destinationMember = snapshot.members[destinationIndex]
        var sourceUsage = sourceMember.usage(for: provider)
        var destinationUsage = destinationMember.usage(for: provider)
        let available = sourceUsage.reclaimableCapacity
        guard capacity <= available else {
            throw CapacityTransferError.insufficientCapacity(
                available: available
            )
        }

        sourceUsage.allocatedCapacity -= capacity
        destinationUsage.allocatedCapacity += capacity
        snapshot.members[sourceIndex].setUsage(sourceUsage, for: provider)
        snapshot.members[destinationIndex].setUsage(
            destinationUsage,
            for: provider
        )
        snapshot.transfers.insert(
            CapacityTransfer(
                id: UUID(),
                provider: provider,
                sourceMemberID: sourceMemberID,
                sourceName: sourceMember.name,
                destinationMemberID: destinationMemberID,
                destinationName: destinationMember.name,
                capacity: capacity,
                createdAt: createdAt
            ),
            at: 0
        )
        snapshot.transfers = Array(snapshot.transfers.prefix(50))
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: persistenceKey)
    }

    static let demoSnapshot: CorporateWorkspaceSnapshot = {
        let calendar = Calendar(identifier: .gregorian)
        let cycleEnd = calendar.date(
            byAdding: .day,
            value: 12,
            to: Date()
        ) ?? Date()

        func id(_ value: String) -> UUID {
            UUID(uuidString: value) ?? UUID()
        }

        return CorporateWorkspaceSnapshot(
            organizationName: "My Workspace",
            cycleEndsAt: cycleEnd,
            autoRebalanceEnabled: false,
            providerPools: [
                CorporateProviderPool(
                    provider: .claude,
                    purchasedSeats: 100,
                    assignedSeats: 92,
                    capacityUsedPercent: 71
                ),
                CorporateProviderPool(
                    provider: .codex,
                    purchasedSeats: 100,
                    assignedSeats: 88,
                    capacityUsedPercent: 64
                )
            ],
            members: [
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000001"),
                    name: "Maya Chen",
                    email: "maya@northstar.example",
                    team: "Product",
                    role: "Product lead",
                    claude: .init(allocatedCapacity: 100, consumedCapacity: 96),
                    codex: .init(allocatedCapacity: 80, consumedCapacity: 42)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000002"),
                    name: "Jon Bell",
                    email: "jon@northstar.example",
                    team: "Engineering",
                    role: "Staff engineer",
                    claude: .init(allocatedCapacity: 90, consumedCapacity: 67),
                    codex: .init(allocatedCapacity: 100, consumedCapacity: 104)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000003"),
                    name: "Priya Shah",
                    email: "priya@northstar.example",
                    team: "Research",
                    role: "Research director",
                    claude: .init(allocatedCapacity: 100, consumedCapacity: 91),
                    codex: .init(allocatedCapacity: 70, consumedCapacity: 39)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000004"),
                    name: "Diego Ruiz",
                    email: "diego@northstar.example",
                    team: "Engineering",
                    role: "Platform engineer",
                    claude: .init(allocatedCapacity: 75, consumedCapacity: 31),
                    codex: .init(allocatedCapacity: 100, consumedCapacity: 94)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000005"),
                    name: "Avery Stone",
                    email: "avery@northstar.example",
                    team: "Operations",
                    role: "Operations manager",
                    claude: .init(allocatedCapacity: 100, consumedCapacity: 18),
                    codex: .init(allocatedCapacity: 80, consumedCapacity: 12)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000006"),
                    name: "Sam Okafor",
                    email: "sam@northstar.example",
                    team: "Finance",
                    role: "Finance partner",
                    claude: .init(allocatedCapacity: 80, consumedCapacity: 22),
                    codex: .init(allocatedCapacity: 60, consumedCapacity: 9)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000007"),
                    name: "Lina Park",
                    email: "lina@northstar.example",
                    team: "Design",
                    role: "Design lead",
                    claude: .init(allocatedCapacity: 100, consumedCapacity: 83),
                    codex: .init(allocatedCapacity: 70, consumedCapacity: 34)
                ),
                CorporateMember(
                    id: id("00000000-0000-0000-0000-000000000008"),
                    name: "Noah Williams",
                    email: "noah@northstar.example",
                    team: "Sales",
                    role: "Account executive",
                    claude: .init(allocatedCapacity: 90, consumedCapacity: 14),
                    codex: .init(allocatedCapacity: 50, consumedCapacity: 6)
                )
            ],
            transfers: [],
            trackedAccounts: CorporateUsageStore.defaultTrackedAccounts
        )
    }()

    static let defaultTrackedAccounts: [TrackedAIAccount] = {
        let resetDate = Calendar.current.date(
            byAdding: .month,
            value: 1,
            to: Date()
        ) ?? Date()

        return [
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                provider: .codex,
                label: "Codex Account 1",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                provider: .codex,
                label: "Codex Account 2",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                provider: .codex,
                label: "Codex Account 3",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                provider: .codex,
                label: "Codex Account 4",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                provider: .claude,
                label: "Claude Account",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            )
        ]
    }()
}
