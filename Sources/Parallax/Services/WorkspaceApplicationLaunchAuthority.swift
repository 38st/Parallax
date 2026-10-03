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
    private var submissionRevision: UInt64 = 0
    private var claims: [ProcessStartIdentity: Claim] = [:]
    private var submissions:
        [WorkspaceApplicationBundleIdentity: SubmissionQueue] = [:]

    private struct PendingSubmission {
        let requestID: UUID
        let waiting: @Sendable (Bool, UInt64, UUID?) -> Void
        let operation:
            @Sendable (WorkspaceApplicationSubmissionSlot) -> Void
    }

    private struct SubmissionQueue {
        var activeRequestID: UUID
        var pending: [PendingSubmission]
        var outcomeUnknown = false
        var revision: UInt64 = 0
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
        waiting: @escaping @Sendable (Bool, UInt64, UUID?) -> Void = { _, _, _ in },
        operation:
            @escaping @Sendable (WorkspaceApplicationSubmissionSlot) -> Void
    ) -> Bool {
        let waitingReason: (Bool, UInt64, UUID?)? = lock.withLock {
            if submissions[application] == nil {
                submissions[application] = SubmissionQueue(
                    activeRequestID: requestID,
                    pending: []
                )
                return nil
            }
            submissions[application]?.pending.append(
                PendingSubmission(
                    requestID: requestID,
                    waiting: waiting,
                    operation: operation
                )
            )
            let queue = submissions[application]
            return (queue?.outcomeUnknown ?? false, queue?.revision ?? 0,
                queue?.outcomeUnknown == true ? queue?.activeRequestID : nil)
        }
        if let waitingReason {
            waiting(waitingReason.0, waitingReason.1, waitingReason.2)
        } else {
            operation(
                makeSubmissionSlot(
                    for: application,
                    requestID: requestID
                )
            )
        }
        return waitingReason == nil
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

    func hasClaim(for process: ProcessStartIdentity) -> Bool {
        lock.withLock { claims[process] != nil }
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
        WorkspaceApplicationSubmissionSlot(outcomeUnknown: { [self] in
            let notification = lock.withLock {
                guard submissions[application]?.activeRequestID == requestID else { return ([PendingSubmission](), submissionRevision) }
                submissionRevision &+= 1
                submissions[application]?.outcomeUnknown = true
                submissions[application]?.revision = submissionRevision
                return (submissions[application]?.pending ?? [], submissionRevision)
            }
            for request in notification.0 { request.waiting(true, notification.1, requestID) }
        }) { [self] in
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
        let result: (PendingSubmission, [PendingSubmission], UInt64)? = lock.withLock {
            guard var queue = submissions[application],
                  queue.activeRequestID == requestID
            else {
                return nil
            }
            guard !queue.pending.isEmpty else {
                submissions.removeValue(forKey: application)
                return nil
            }
            let next = queue.pending.removeFirst()
            queue.activeRequestID = next.requestID
            queue.outcomeUnknown = false
            submissionRevision &+= 1
            queue.revision = submissionRevision
            submissions[application] = queue
            return (next, queue.pending, submissionRevision)
        }
        guard let (next, pending, revision) = result else { return }
        for request in pending { request.waiting(false, revision, nil) }
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
    private let outcomeUnknown: @Sendable () -> Void

    fileprivate init(outcomeUnknown: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
        self.outcomeUnknown = outcomeUnknown
        self.completion = completion
    }

    func markOutcomeUnknown() { outcomeUnknown() }

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
