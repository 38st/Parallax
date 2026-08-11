import SwiftUI

func relayColor(for tone: RelayPresentationTone) -> Color {
    switch tone {
    case .neutral: .secondary
    case .accent: .accentColor
    case .active: .green
    case .warning: .orange
    case .failure: .red
    }
}

struct RelayStatusBadge: View {
    let label: String
    let systemImage: String
    let tone: RelayPresentationTone
    let accessibilityIdentifier: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(relayColor(for: tone))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                relayColor(for: tone).opacity(0.1),
                in: Capsule()
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct RelayLabeledValue: View {
    let label: String
    let value: String
    var isMonospaced = false

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fontDesign(isMonospaced ? .monospaced : .default)
        }
        .font(.caption)
    }
}

struct RelaySectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RelayEmptySection: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
