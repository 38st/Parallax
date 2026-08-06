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

struct TrackedAIAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var provider: AIProvider
    var label: String
    var email: String
    var planName: String
    var usagePercent: Int
    var resetsAt: Date
    var lastCheckedAt: Date?
    var isConnected: Bool?
    var lifetimeTokens: Int?

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
@Observable
final class CorporateUsageStore {
    private(set) var snapshot: CorporateWorkspaceSnapshot
    private let userDefaults: UserDefaults
    private let persistenceKey: String

    var organizationName: String { snapshot.organizationName }
    var cycleEndsAt: Date { snapshot.cycleEndsAt }
    var providerPools: [CorporateProviderPool] { snapshot.providerPools }
    var members: [CorporateMember] { snapshot.members }
    var transfers: [CapacityTransfer] { snapshot.transfers }
    var autoRebalanceEnabled: Bool { snapshot.autoRebalanceEnabled }
    var trackedAccounts: [TrackedAIAccount] {
        snapshot.trackedAccounts ?? Self.defaultTrackedAccounts
    }

    init(
        userDefaults: UserDefaults = .standard,
        persistenceKey: String = "corporate.workspace.v1",
        initialSnapshot: CorporateWorkspaceSnapshot? = nil
    ) {
        self.userDefaults = userDefaults
        self.persistenceKey = persistenceKey

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
