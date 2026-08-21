import Foundation

/// Compatibility-only representation of the organization data written by the
/// original `corporate.workspace.v1` account tracker. The current product does
/// not expose or mutate this deferred enterprise data, but preserving the
/// fields prevents an account edit from silently discarding legacy values.
private struct LegacyCorporateSeatUsage: Codable, Equatable, Sendable {
    var allocatedCapacity: Int
    var consumedCapacity: Int
}

private struct LegacyCorporateMember: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var email: String
    var team: String
    var role: String
    var claude: LegacyCorporateSeatUsage
    var codex: LegacyCorporateSeatUsage
}

private struct LegacyCorporateProviderPool: Codable, Equatable, Sendable {
    let provider: AIProvider
    var purchasedSeats: Int
    var assignedSeats: Int
    var capacityUsedPercent: Int
}

private struct LegacyCapacityTransfer: Codable, Equatable, Sendable {
    let id: UUID
    let provider: AIProvider
    let sourceMemberID: UUID
    let sourceName: String
    let destinationMemberID: UUID
    let destinationName: String
    let capacity: Int
    let createdAt: Date
}

struct LegacyCorporateWorkspaceEnvelope: Codable, Equatable, Sendable {
    static let currentTrackedAccountSchemaVersion = 3

    private var organizationName: String
    private var cycleEndsAt: Date
    private var autoRebalanceEnabled: Bool
    private var providerPools: [LegacyCorporateProviderPool]
    private var members: [LegacyCorporateMember]
    private var transfers: [LegacyCapacityTransfer]
    var trackedAccounts: [TrackedAIAccount]?
    var trackedAccountSchemaVersion: Int?

    static func fresh(trackedAccounts: [TrackedAIAccount]) -> Self {
        Self(
            organizationName: "",
            cycleEndsAt: Date(timeIntervalSince1970: 0),
            autoRebalanceEnabled: false,
            providerPools: [],
            members: [],
            transfers: [],
            trackedAccounts: trackedAccounts,
            trackedAccountSchemaVersion: currentTrackedAccountSchemaVersion
        )
    }
}
