import SwiftUI

struct RelayEvidenceView: View {
    let evidence: [RelayEvidencePresentation]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RelaySectionHeader(
                String(localized: "Evidence"),
                detail: String(
                    localized:
                        "Captured and independently reproduced evidence are distinct from agent claims."
                )
            )

            if evidence.isEmpty {
                RelayEmptySection(
                    title: String(localized: "No Evidence Recorded"),
                    systemImage: "doc.text.magnifyingglass",
                    description: String(
                        localized: "A claim without captured evidence cannot satisfy verification."
                    )
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(evidence) { item in
                        RelayEvidenceRow(evidence: item)
                    }
                }
            }
        }
    }
}

private struct RelayEvidenceRow: View {
    let evidence: RelayEvidencePresentation

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let detail = evidence.detail {
                    Text(detail)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    if let command = evidence.command {
                        RelayLabeledValue(
                            label: String(localized: "Command"),
                            value: command,
                            isMonospaced: true
                        )
                    }
                    if let directory = evidence.workingDirectory {
                        RelayLabeledValue(
                            label: String(localized: "Working directory"),
                            value: directory,
                            isMonospaced: true
                        )
                    }
                    if let startedAt = evidence.startedAt {
                        RelayLabeledValue(
                            label: String(localized: "Started"),
                            value: startedAt.formatted(
                                date: .abbreviated,
                                time: .standard
                            )
                        )
                    }
                    if let endedAt = evidence.endedAt {
                        RelayLabeledValue(
                            label: String(localized: "Ended"),
                            value: endedAt.formatted(
                                date: .abbreviated,
                                time: .standard
                            )
                        )
                    }
                    if let exitCode = evidence.exitCode {
                        RelayLabeledValue(
                            label: String(localized: "Exit code"),
                            value: String(exitCode),
                            isMonospaced: true
                        )
                    }
                    if let digest = evidence.digest {
                        RelayLabeledValue(
                            label: String(localized: "Digest"),
                            value: digest,
                            isMonospaced: true
                        )
                    }
                }

                if evidence.status == .running {
                    Label(runningDescription, systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let output = evidence.output {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Captured Output")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if evidence.isOutputTruncated {
                                Label("Truncated", systemImage: "scissors")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        ScrollView([.horizontal, .vertical]) {
                            Text(output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: 240)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else if evidence.status == .unavailable {
                    Label(
                        "The referenced evidence is unavailable.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if evidence.status == .redacted {
                    Label(
                        "Sensitive values were replaced with redaction markers.",
                        systemImage: "eye.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: evidence.kind.systemImage)
                    .foregroundStyle(relayColor(for: evidence.status.tone))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(evidence.title)
                        .font(.body.weight(.medium))
                    Text(
                        verbatim:
                            "\(evidence.id) · \(evidence.kind.label)"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(evidence.status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(relayColor(for: evidence.status.tone))
            }
        }
        .tint(.secondary)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                verbatim:
                    "\(evidence.id), \(evidence.kind.label), \(evidence.title), \(evidence.status.label)"
            )
        )
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.evidence(evidence.id)
        )
    }

    private var runningDescription: String {
        if let lastOutputAt = evidence.lastOutputAt {
            return String(
                format: String(localized: "Running; last output %@"),
                lastOutputAt.formatted(date: .omitted, time: .standard)
            )
        }
        return String(localized: "Running; no output captured yet")
    }
}
