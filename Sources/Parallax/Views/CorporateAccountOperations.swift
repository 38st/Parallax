import Foundation

extension CorporateAccountTrackerContent {
    func activity(
        for account: TrackedAIAccount
    ) -> AccountConnectionActivity {
        operationCoordinator.activity(for: account)
    }

    func accounts(for provider: AIProvider) -> [TrackedAIAccount] {
        store.trackedAccounts.filter { $0.provider == provider }
    }

    func providerCount(_ provider: AIProvider) -> Int {
        accounts(for: provider).count
    }

    var currentNearLimitCount: Int {
        CorporateAccountUsageAggregation(
            accounts: store.trackedAccounts,
            now: store.currentDate
        )
            .nearLimitAccounts.count
    }

    @MainActor
    func addAndConnect(_ provider: AIProvider) {
        guard let account = store.addTrackedAccount(provider: provider) else {
            return
        }
        operationCoordinator.startConnect(account)
    }
}
