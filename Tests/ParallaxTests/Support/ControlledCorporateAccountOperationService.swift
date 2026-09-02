import Foundation
@testable import Parallax

/// Shared test double: every call suspends until a test completes or fails
/// it, so in-flight state and cancellation are observable.
final class ControlledCorporateAccountOperationService:
    @unchecked Sendable,
    CorporateAccountOperationServicing
{
    struct Call: Hashable {
        enum Kind: Hashable {
            case login
            case refresh
        }

        let kind: Kind
        let provider: AIProvider
        let accountID: UUID
    }

    private struct PendingCall {
        let continuation:
            CheckedContinuation<ConnectedAIAccountStatus, any Error>
    }

    private let lock = NSLock()
    private var pendingCalls: [Call: [PendingCall]] = [:]
    private var callCounts: [Call: Int] = [:]
    private var cancellationCounts: [Call: Int] = [:]

    func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await perform(
            Call(kind: .login, provider: provider, accountID: accountID)
        )
    }

    func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await perform(
            Call(kind: .refresh, provider: provider, accountID: accountID)
        )
    }

    func callCount(_ call: Call) -> Int {
        withLock { callCounts[call, default: 0] }
    }

    func cancellationCount(_ call: Call) -> Int {
        withLock { cancellationCounts[call, default: 0] }
    }

    func completeOldest(
        _ call: Call,
        with status: ConnectedAIAccountStatus
    ) {
        let pending: PendingCall? = withLock {
            guard var calls = pendingCalls[call], !calls.isEmpty else {
                return nil
            }
            let pending = calls.removeFirst()
            pendingCalls[call] = calls
            return pending
        }
        pending?.continuation.resume(returning: status)
    }

    func failOldest(_ call: Call, with error: any Error) {
        let pending: PendingCall? = withLock {
            guard var calls = pendingCalls[call], !calls.isEmpty else {
                return nil
            }
            let pending = calls.removeFirst()
            pendingCalls[call] = calls
            return pending
        }
        pending?.continuation.resume(throwing: error)
    }

    private func perform(
        _ call: Call
    ) async throws -> ConnectedAIAccountStatus {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                withLock {
                    callCounts[call, default: 0] += 1
                    pendingCalls[call, default: []].append(
                        PendingCall(continuation: continuation)
                    )
                }
            }
        } onCancel: {
            self.withLock {
                self.cancellationCounts[call, default: 0] += 1
            }
        }
    }

    private func withLock<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
