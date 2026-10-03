import AppKit
import Foundation
import Observation

extension CorporateAccountOperationCoordinator {
    /// Starts the periodic pass, a delayed pass after wake from sleep, and
    /// cancellation of in-flight provider tools when the app terminates.
    func startAutomaticRefresh(
        interval: TimeInterval = automaticRefreshInterval,
        initialDelay: TimeInterval = 5
    ) {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDueAccounts()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        observeLifecycleEvents()
    }

    func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    func prepareForTermination() {
        stopAutomaticRefresh()
        cancelAll()
        service.terminateProviderProcesses()
    }

    /// Refreshes every connected account whose automatic check is due,
    /// including accounts whose last refresh reported sign-in required: the
    /// probe is local, opens no browser, and self-heals the row once the
    /// provider answers normally again.
    func refreshDueAccounts() async {
        let now = store.currentDate
        let due = store.trackedAccounts.filter { isDue($0, now: now) }
        await refresh(due)
    }

    func isDue(_ account: TrackedAIAccount, now: Date) -> Bool {
        guard account.isConnected == true else { return false }
        // An interrupted attempt, for example from quitting mid-refresh, did
        // not probe the provider, so it does not delay the next check.
        if account.lastRefreshFailure == .interrupted { return true }
        if let attempt = account.lastRefreshAttemptAt,
            attempt <= now,
            now.timeIntervalSince(attempt)
                < automaticRetryInterval(for: account)
        {
            return false
        }
        if let success = account.lastSuccessfulRefreshAt,
            success <= now,
            now.timeIntervalSince(success) < automaticRetryInterval(for: account)
        {
            return false
        }
        return true
    }

    /// Spacing before an account is automatically probed again. Healthy
    /// accounts use the minimum; each consecutive failure doubles the wait,
    /// starting at one pass interval.
    func automaticRetryInterval(for account: TrackedAIAccount) -> TimeInterval {
        let failures = consecutiveFailures[account.id, default: 0]
        guard failures > 0 else { return Self.minimumAutomaticRetryInterval }
        let scaled = Self.automaticRefreshInterval
            * pow(2, Double(min(failures, 10) - 1))
        return min(scaled, Self.maximumAutomaticRetryInterval)
    }
}
