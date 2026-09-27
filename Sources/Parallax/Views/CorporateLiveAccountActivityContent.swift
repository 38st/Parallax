import SwiftUI

private typealias ProviderMark = CorporateProviderMarkContent

private extension View {
    func corporateCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }
}

struct CorporateLiveAccountActivityContent: View {
    @Bindable var store: CorporateUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.largeTitle.weight(.semibold))
                Text("Provider refresh attempts recorded from tracked accounts.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(28)

            if syncedAccounts.isEmpty {
                ContentUnavailableView(
                    "No account activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sign in or refresh an account to record a sync.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(syncedAccounts.enumerated()), id: \.element.id) { index, account in
                            HStack(spacing: 12) {
                                ProviderMark(provider: account.provider)
                                    .scaleEffect(0.82)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        CorporateAccountStatusPresentation(
                                            account: account,
                                            now: store.currentDate,
                                            inFlightAttemptKind:
                                                store.inFlightAttemptKind(
                                                    for: account.id
                                                )
                                        ).activityTitle
                                    )
                                        .font(.callout.weight(.medium))
                                    Text(account.email.isEmpty ? account.provider.displayName : account.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let attemptedAt = account.lastRefreshAttemptAt {
                                    Text(attemptedAt, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(16)
                            if index < syncedAccounts.count - 1 { Divider() }
                        }
                    }
                    .corporateCard()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationTitle("Activity")
    }

    private var syncedAccounts: [TrackedAIAccount] {
        store.trackedAccounts
            .filter { $0.lastRefreshAttemptAt != nil }
            .sorted {
                ($0.lastRefreshAttemptAt ?? .distantPast)
                    > ($1.lastRefreshAttemptAt ?? .distantPast)
            }
    }
}
