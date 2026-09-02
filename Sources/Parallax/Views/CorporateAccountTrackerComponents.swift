import SwiftUI

struct CorporateAccountSummaryCardContent: View {
    let value: String
    let label: String
    let systemImage: String
    let tone: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(tone)
                .frame(width: 34, height: 34)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .corporateCard()
        .frame(maxWidth: .infinity)
    }
}

struct CorporateAccountStatusPillContent: View {
    let account: TrackedAIAccount
    let now: Date
    var inFlightAttemptKind: TrackedAccountAttemptKind? = nil

    var body: some View {
        Text(presentation.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.1), in: Capsule())
            .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var presentation: CorporateAccountStatusPresentation {
        CorporateAccountStatusPresentation(
            account: account,
            now: now,
            inFlightAttemptKind: inFlightAttemptKind
        )
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .secondary: .secondary
        case .available: .green
        case .attention: .orange
        }
    }
}

struct CorporateAccountTrackingNoticeContent: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.tap")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Secure provider sign-in")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(
                            CorporateAccountIsolationPresentation(
                                provider: provider
                            ).capabilityDetail
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }
}

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
