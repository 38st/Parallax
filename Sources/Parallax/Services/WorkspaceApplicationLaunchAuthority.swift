import Foundation

/// Process-local arbitration for exact processes returned by Launch Services.
///
/// Two requests can take their pre-open snapshots concurrently and both receive
/// the same singleton process. The snapshot alone cannot distinguish which
/// request created it, so exactly one request may claim that process identity.
final class WorkspaceApplicationLaunchAuthority: @unchecked Sendable {
    static let shared = WorkspaceApplicationLaunchAuthority()

    private struct Claim {
        let requestID: UUID
        let identity: WorkspaceProcessIdentity
    }

    private let lock = NSLock()
    private var claims: [ProcessStartIdentity: Claim] = [:]
    private var submissions:
        [WorkspaceApplicationBundleIdentity: SubmissionQueue] = [:]

    private struct PendingSubmission {
        let requestID: UUID
        let operation:
            @Sendable (WorkspaceApplicationSubmissionSlot) -> Void
    }

    private struct SubmissionQueue {
        var activeRequestID: UUID
        var pending: [PendingSubmission]
    }

    /// Serializes Launch Services submissions for one canonical application
    /// identity. A queued operation does not take its process snapshot or time
    /// boundary until every earlier opener callback has been classified.
    ///
    /// - Returns: `true` when `operation` began before this method returned.
    @discardableResult
    func enqueueSubmission(
        for application: WorkspaceApplicationBundleIdentity,
        requestID: UUID,
        operation:
            @escaping @Sendable (WorkspaceApplicationSubmissionSlot) -> Void
    ) -> Bool {
        let shouldBegin = lock.withLock {
            if submissions[application] == nil {
                submissions[application] = SubmissionQueue(
                    activeRequestID: requestID,
                    pending: []
                )
                return true
            }
            submissions[application]?.pending.append(
                PendingSubmission(
                    requestID: requestID,
                    operation: operation
                )
            )
            return false
        }
        if shouldBegin {
            operation(
                makeSubmissionSlot(
                    for: application,
                    requestID: requestID
                )
            )
        }
        return shouldBegin
    }

    func claim(
        _ identity: WorkspaceProcessIdentity,
        requestID: UUID
    ) -> Bool {
        lock.withLock {
            guard claims[identity.process] == nil else {
                return false
            }
            claims[identity.process] = Claim(
                requestID: requestID,
                identity: identity
            )
            return true
        }
    }

    func release(
        _ identity: WorkspaceProcessIdentity,
        requestID: UUID
    ) {
        lock.withLock {
            guard
                let claim = claims[identity.process],
                claim.requestID == requestID,
                claim.identity == identity
            else {
                return
            }
            claims.removeValue(forKey: identity.process)
        }
    }

    func isClaimed(
        _ identity: WorkspaceProcessIdentity,
        requestID: UUID
    ) -> Bool {
        lock.withLock {
            guard let claim = claims[identity.process] else {
                return false
            }
            return claim.requestID == requestID
                && claim.identity == identity
        }
    }

    private func makeSubmissionSlot(
        for application: WorkspaceApplicationBundleIdentity,
        requestID: UUID
    ) -> WorkspaceApplicationSubmissionSlot {
        WorkspaceApplicationSubmissionSlot { [self] in
            completeSubmission(
                for: application,
                requestID: requestID
            )
        }
    }

    private func completeSubmission(
        for application: WorkspaceApplicationBundleIdentity,
        requestID: UUID
    ) {
        let next = lock.withLock {
            guard var queue = submissions[application],
                  queue.activeRequestID == requestID
            else {
                return Optional<PendingSubmission>.none
            }
            guard !queue.pending.isEmpty else {
                submissions.removeValue(forKey: application)
                return nil
            }
            let next = queue.pending.removeFirst()
            queue.activeRequestID = next.requestID
            submissions[application] = queue
            return next
        }
        guard let next else { return }
        next.operation(
            makeSubmissionSlot(
                for: application,
                requestID: next.requestID
            )
        )
    }
}

final class WorkspaceApplicationSubmissionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?

    fileprivate init(completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    /// Advances the per-application queue at most once. If an opener never
    /// calls back, this method is never reached and later submissions remain
    /// safely stalled rather than being reordered.
    func complete() {
        let completion = lock.withLock {
            let completion = self.completion
            self.completion = nil
            return completion
        }
        completion?()
    }
}
