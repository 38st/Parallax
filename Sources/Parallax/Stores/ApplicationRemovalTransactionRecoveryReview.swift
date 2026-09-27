import Foundation
import Observation

struct ApplicationRemovalRecoveryReview: Identifiable, Equatable, Sendable {
    let transactionID: UUID
    let manifestSHA256: String
    let locations: [URL]

    var id: UUID { transactionID }
}

struct ApplicationRemovalRecoveryJournalReview: Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case notAttempted
        case failed(String)
        case unreadable(String)

        var message: String {
            switch self {
            case .notAttempted:
                String(localized: "Recovery has not been attempted for this transaction in this session. Retry before deciding to keep its files.")
            case .failed(let message), .unreadable(let message):
                message
            }
        }
    }

    let id: UUID
    let review: ApplicationRemovalRecoveryReview?
    let status: Status
}

struct ApplicationRemovalPreservedFiles: Identifiable, Sendable {
    let id: UUID
    let applicationStorageID: UUID
    let locations: [URL]
}

struct ApplicationRemovalRecoveryInventory: Sendable {
    let pending: [ApplicationRemovalRecoveryJournalReview]
    let preserved: [ApplicationRemovalPreservedFiles]
}

/// Owned by the store's coordinator. Views only read this cache; refreshes
/// read local journals off the main actor and never probe the recorded paths.
@MainActor
@Observable
final class ApplicationRemovalRecoveryPresentation {
    var pendingSceneMessages: [UUID: String] = [:]
    var inventory = ApplicationRemovalRecoveryInventory(pending: [], preserved: [])
    var listingError: String?
    var isRefreshing = false
    var refreshGeneration: UInt = 0
    @ObservationIgnored var refreshTask: Task<Result<ApplicationRemovalRecoveryInventory, Error>, Never>?

    nonisolated init() {}
}

final class ApplicationRemovalRecoveryAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [UUID: String] = [:]

    func recordFailure(_ error: any Error, transactionID: UUID) {
        lock.withLock { failures[transactionID] = error.localizedDescription }
    }

    func clear(_ transactionID: UUID) {
        lock.withLock { _ = failures.removeValue(forKey: transactionID) }
    }

    func message(for transactionID: UUID) -> String? {
        lock.withLock { failures[transactionID] }
    }

    func contains(message: String) -> Bool {
        lock.withLock { failures.values.contains(message) }
    }
}

struct ApplicationRemovalRecoveryMessage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Startup wraps only discovery/recovery failures from the application-removal
/// coordinator, so its outer load handler can distinguish journal recovery
/// from a damaged library or another kind of pending transaction.
struct ApplicationRemovalPendingRecoveryFailure: LocalizedError {
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }
}
