import SwiftUI

struct RelayHumanGateCard: View {
    let gate: RelayHumanGatePresentation
    let taskID: UUID
    let approve: () -> Void
    let requestDenial: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(gate.title)
                        .font(.headline)
                    Text(gate.state.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                Spacer()
            }

            Grid(
                alignment: .leading,
                horizontalSpacing: 16,
                verticalSpacing: 7
            ) {
                RelayLabeledValue(
                    label: String(localized: "Requested action"),
                    value: gate.requestedAction
                )
                RelayLabeledValue(
                    label: String(localized: "Target"),
                    value: gate.target,
                    isMonospaced: true
                )
                RelayLabeledValue(
                    label: String(localized: "Authority"),
                    value: gate.authority
                )
                RelayLabeledValue(
                    label: String(localized: "Side effects"),
                    value: gate.sideEffects
                )
                RelayLabeledValue(
                    label: String(localized: "Reversibility"),
                    value: gate.reversibility
                )
                if let evidence = gate.evidenceSummary {
                    RelayLabeledValue(
                        label: String(localized: "Evidence"),
                        value: evidence
                    )
                }
            }

            HStack {
                Text(
                    "Approval applies only to this exact request."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Deny…", action: requestDenial)
                    .disabled(gate.state != .pending)
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.denyGate(gate.id)
                    )

                Button("Approve Once", action: approve)
                    .buttonStyle(.borderedProminent)
                    .disabled(gate.state != .pending)
                    .accessibilityHint(
                        Text("Approves only the action and target shown here")
                    )
                    .accessibilityIdentifier(
                        RelayAccessibilityIdentifier.approveGate(gate.id)
                    )
            }
        }
        .padding(16)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.3))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                String(
                    format: String(localized: "Decision required: %@"),
                    gate.title
                )
            )
        )
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.gate(gate.id)
        )
    }
}

struct RelayGateDenialView: View {
    let gate: RelayHumanGatePresentation
    let cancel: () -> Void
    let deny: (String) -> Void

    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Deny Request")
                    .font(.title2.bold())
                Text(gate.title)
                    .foregroundStyle(.secondary)
            }

            Text(
                "The reason becomes part of the durable handoff so the relay can respond without guessing."
            )
            .font(.callout)

            TextField(
                "Reason for denying this request",
                text: $reason,
                axis: .vertical
            )
            .lineLimit(3...7)
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Deny Request", role: .destructive) {
                    deny(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(
                    reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
