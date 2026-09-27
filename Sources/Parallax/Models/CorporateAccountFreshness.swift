import Foundation

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
    /// An operation is running and the previous values are no longer
    /// current. Distinct from `.failed(.interrupted)`, which is what the same
    /// persisted record means once no operation is alive.
    case refreshing(
        kind: TrackedAccountAttemptKind,
        lastSuccessfulRefreshAt: Date?
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

    /// - Parameter inFlightAttemptKind: The kind of operation currently
    ///   running for this account, if any. The persisted record deliberately
    ///   looks interrupted while an operation runs (so a crash is never
    ///   mistaken for success); this parameter lets every presentation tell
    ///   the two apart and keep still-current values on screen.
    static func state(
        for account: TrackedAIAccount,
        now: Date,
        ageThreshold: TimeInterval = currentAgeThreshold,
        inFlightAttemptKind: TrackedAccountAttemptKind? = nil
    ) -> CorporateAccountFreshnessState {
        let success = account.lastSuccessfulRefreshAt
        let attempt = account.lastRefreshAttemptAt
        let completion = account.lastRefreshCompletedAt

        if let inFlightAttemptKind {
            if !account.needsSignIn, let success,
                success <= now,
                now.timeIntervalSince(success) <= max(ageThreshold, 0)
            {
                return .current(lastSuccessfulRefreshAt: success)
            }
            return .refreshing(
                kind: inFlightAttemptKind,
                lastSuccessfulRefreshAt: success
            )
        }

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
