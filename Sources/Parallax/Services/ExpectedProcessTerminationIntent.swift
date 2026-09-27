import AppKit
import Foundation

/// Shared across windows; only the exact process may inherit a quit intent.
final class ExpectedProcessTerminationIntent: @unchecked Sendable {
    static let shared = ExpectedProcessTerminationIntent()
    private let lock = NSLock()
    private var intents:
        [WorkspaceProcessIdentity: (token: UUID, deadline: ContinuousClock.Instant)] = [:]

    func mark(_ process: WorkspaceProcessIdentity, token: UUID) {
        lock.withLock {
            intents = intents.filter { $0.value.deadline > ContinuousClock.now }
            intents[process] = (
                token,
                ContinuousClock.now.advanced(
                    by: .seconds(LaunchHistoryStore.terminationRequestGracePeriod))
            )
        }
    }

    func cancel(_ process: WorkspaceProcessIdentity, token: UUID) {
        lock.withLock {
            if intents[process]?.token == token { intents[process] = nil }
        }
    }

    func clear(_ process: WorkspaceProcessIdentity) {
        _ = lock.withLock { intents.removeValue(forKey: process) }
    }

    func contains(_ process: WorkspaceProcessIdentity) -> Bool {
        lock.withLock { intents[process].map { $0.deadline > ContinuousClock.now } ?? false }
    }
}
