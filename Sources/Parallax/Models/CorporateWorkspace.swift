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
    /// operation scope with no cap on how many can be tracked. The coordinator
    /// also serializes Codex browser logins, which share a callback port.
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
    case persistenceUnavailable
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
        case .persistenceUnavailable:
            String(localized: "Account changes could not be saved. The previous saved data is unchanged.")
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
