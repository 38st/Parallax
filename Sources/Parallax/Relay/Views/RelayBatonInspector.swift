import SwiftUI

struct RelayBatonInspector: View {
    let baton: RelayBatonPresentation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Handoff")
                        .font(.title2.bold())
                    Text(
                        verbatim:
                            "\(baton.sourceStage) → \(baton.destinationStage)"
                    )
                        .foregroundStyle(.secondary)
                    if baton.isStale {
                        Label(
                            "This handoff references stale workspace state.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 12,
                    verticalSpacing: 6
                ) {
                    RelayLabeledValue(
                        label: String(localized: "Task revision"),
                        value: String(baton.taskRevision)
                    )
                    RelayLabeledValue(
                        label: String(localized: "Recorded"),
                        value: baton.recordedAt.formatted(
                            date: .abbreviated,
                            time: .standard
                        )
                    )
                    RelayLabeledValue(
                        label: String(localized: "Workspace commit"),
                        value: baton.workspaceCommit
                            ?? String(localized: "Unavailable"),
                        isMonospaced: true
                    )
                }

                batonSection(
                    String(localized: "Objective"),
                    values: [baton.objective]
                )
                batonSection(
                    String(localized: "Acceptance Criteria"),
                    values: baton.acceptanceCriteria
                )
                batonSection(
                    String(localized: "Changes"),
                    values: baton.changes,
                    empty: String(localized: "No changes recorded")
                )
                batonSection(
                    String(localized: "Evidence"),
                    values: baton.evidenceIDs,
                    empty: String(localized: "No evidence recorded")
                )
                batonSection(
                    String(localized: "Open Findings"),
                    values: baton.openFindingIDs,
                    empty: String(localized: "No open findings")
                )
                batonSection(
                    String(localized: "Residual Risks"),
                    values: baton.residualRisks,
                    empty: String(localized: "No residual risks recorded")
                )
            }
            .padding(18)
        }
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.baton(baton.id)
        )
    }

    private func batonSection(
        _ title: String,
        values: [String],
        empty: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if values.isEmpty, let empty {
                Text(empty)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(verbatim: "• \(value)")
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}
