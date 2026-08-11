import SwiftUI

struct RelayProgressView: View {
    let task: RelayTaskPresentation
    let showBaton: (RelayBatonPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let completion = task.completion {
                RelayCompletionCard(
                    completion: completion,
                    taskID: task.id
                )
            }

            RelaySectionHeader(
                String(localized: "Stages"),
                detail: String(
                    localized:
                        "Each stage keeps every attempt and the evidence behind its disposition."
                )
            )

            if task.stages.isEmpty {
                RelayEmptySection(
                    title: String(localized: "No Stages Recorded"),
                    systemImage: "list.bullet.rectangle",
                    description: String(
                        localized: "The relay has not recorded a pipeline yet."
                    )
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(task.stages.sorted { $0.position < $1.position }.enumerated()),
                        id: \.element.id
                    ) { index, stage in
                        RelayStageRow(
                            stage: stage,
                            isLast: index == task.stages.count - 1,
                            incomingBaton: baton(stage.incomingBatonID),
                            outgoingBaton: baton(stage.outgoingBatonID),
                            showBaton: showBaton
                        )
                    }
                }
            }
        }
    }

    private func baton(_ id: UUID?) -> RelayBatonPresentation? {
        guard let id else { return nil }
        return task.batons.first { $0.id == id }
    }
}

private struct RelayStageRow: View {
    let stage: RelayStagePresentation
    let isLast: Bool
    let incomingBaton: RelayBatonPresentation?
    let outgoingBaton: RelayBatonPresentation?
    let showBaton: (RelayBatonPresentation) -> Void

    @State private var isExpanded: Bool

    init(
        stage: RelayStagePresentation,
        isLast: Bool,
        incomingBaton: RelayBatonPresentation?,
        outgoingBaton: RelayBatonPresentation?,
        showBaton: @escaping (RelayBatonPresentation) -> Void
    ) {
        self.stage = stage
        self.isLast = isLast
        self.incomingBaton = incomingBaton
        self.outgoingBaton = outgoingBaton
        self.showBaton = showBaton
        _isExpanded = State(
            initialValue: stage.isCurrent
                || stage.status == .rejected
                || stage.status == .failed
                || stage.status == .interrupted
                || stage.status == .blocked
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: stage.status.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(relayColor(for: stage.status.tone))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 2)
                        .frame(minHeight: 48)
                        .accessibilityHidden(true)
                }
            }

            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if let incomingBaton {
                        Button("View Incoming Handoff") {
                            showBaton(incomingBaton)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier(
                            RelayAccessibilityIdentifier.baton(incomingBaton.id)
                        )
                    }

                    ForEach(stage.attempts) { attempt in
                        RelayAttemptRow(attempt: attempt)
                    }

                    if let outgoingBaton {
                        Button("View Outgoing Handoff") {
                            showBaton(outgoingBaton)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier(
                            RelayAccessibilityIdentifier.baton(outgoingBaton.id)
                        )
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.name)
                            .font(.body.weight(.semibold))
                        Text(stage.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(stage.status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(relayColor(for: stage.status.tone))
                }
            }
            .tint(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                String(
                    format: String(
                        localized:
                            "Stage %1$lld, %2$@, role %3$@, %4$@"
                    ),
                    Int64(stage.position),
                    stage.name,
                    stage.role,
                    stage.status.label
                )
            )
        )
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.stage(stage.id)
        )
    }
}

private struct RelayAttemptRow: View {
    let attempt: RelayAttemptPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(attempt.title)
                    .font(.caption.weight(.semibold))
                Text(attempt.status.label)
                    .font(.caption)
                    .foregroundStyle(relayColor(for: attempt.status.tone))
                Spacer()
                if let startedAt = attempt.startedAt {
                    Text(startedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = attempt.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !attempt.returnReasonFindingIDs.isEmpty {
                Text(
                    String(
                        format: String(
                            localized: "Returned upstream because %@"
                        ),
                        attempt.returnReasonFindingIDs.joined(separator: ", ")
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.attempt(attempt.id)
        )
    }
}

private struct RelayCompletionCard: View {
    let completion: RelayCompletionPresentation
    let taskID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(completion.title)
                        .font(.headline)
                    Text(completion.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(completion.criteria) { criterion in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: criterion.status.systemImage)
                            .foregroundStyle(
                                criterion.status == .failed ? .red : .secondary
                            )
                            .accessibilityHidden(true)
                        Text(criterion.text)
                        Spacer()
                        Text(criterion.status.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !completion.residualRisks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Residual Risks")
                        .font(.caption.weight(.semibold))
                    ForEach(completion.residualRisks, id: \.self) { risk in
                        Text(verbatim: "• \(risk)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let artifact = completion.artifactLabel {
                LabeledContent("Artifact", value: artifact)
                    .font(.caption)
            }
            if let approval = completion.approvalSummary {
                LabeledContent("Approval", value: approval)
                    .font(.caption)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.completion(taskID)
        )
    }
}
