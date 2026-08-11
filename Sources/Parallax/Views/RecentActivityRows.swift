import SwiftUI

struct RecentActivityEntryRow: View {
    let entry: LaunchHistoryEntry
    let crashReport: ApplicationCrashReport?
    let identity: ProfileInstanceVisualIdentity
    @Binding var isExpanded: Bool
    let canReopen: Bool
    let openCrashReport: (ApplicationCrashReport) -> Void
    let reopen: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            RecentActivityEntryDetails(
                entry: entry,
                presentation: presentation,
                crashReport: crashReport,
                canReopen: canReopen,
                openCrashReport: openCrashReport,
                reopen: reopen
            )
        } label: {
            HStack(spacing: 12) {
                ProfileInstanceIdentityMark(
                    identity: identity,
                    isTrackedSpace: true
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.profileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Image(
                            systemName: presentation.systemImageName
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            color(for: presentation.tone)
                        )
                        .accessibilityHidden(true)
                        Text(presentation.statusLabel)
                        Text("·")
                        Text(presentation.timeLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let duration = presentation.durationLabel {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        .padding(.horizontal, 14)
        .tint(.secondary)
        .accessibilityIdentifier(
            "launch-history.entry.\(entry.requestID.uuidString.lowercased())"
        )
    }

    private var presentation: LaunchHistoryEntryPresentation {
        LaunchHistoryEntryPresentation(
            entry: entry,
            crashReport: crashReport
        )
    }

    private var accessibilityLabel: Text {
        if let duration = presentation.durationLabel {
            return Text(
                "\(entry.profileName), \(presentation.statusLabel), \(presentation.timeLabel), \(duration)"
            )
        }
        return Text(
            "\(entry.profileName), \(presentation.statusLabel), \(presentation.timeLabel)"
        )
    }

    private func color(
        for tone: LaunchHistoryPresentationTone
    ) -> Color {
        switch tone {
        case .neutral:
            .secondary
        case .active:
            .green
        case .warning:
            .orange
        case .failure:
            .red
        }
    }
}

struct RecentActivityCrashReportRow: View {
    let report: ApplicationCrashReport
    @Binding var isExpanded: Bool
    let openCrashReport: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 12,
                    verticalSpacing: 5
                ) {
                    RecentActivityDetailRow(
                        "Process",
                        value: String(report.processIdentifier)
                    )
                    RecentActivityDetailRow(
                        "Crashed",
                        value: formatted(report.capturedAt)
                    )
                    if let launchedAt = report.launchedAt {
                        RecentActivityDetailRow(
                            "Launched",
                            value: formatted(launchedAt)
                        )
                    }
                    if let exceptionType = report.exceptionType {
                        RecentActivityDetailRow(
                            "Exception",
                            value: exceptionType
                        )
                    }
                    if let signal = report.signal {
                        RecentActivityDetailRow("Signal", value: signal)
                    }
                }

                if let reason = report.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Text("Not linked to a recorded Parallax launch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Open Crash Report") {
                        openCrashReport()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.leading, 48)
            .padding(.bottom, 12)
        } label: {
            HStack(spacing: 12) {
                Image(
                    systemName: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 36, height: 36)
                .background(
                    Color.red.opacity(0.12),
                    in: RoundedRectangle(
                        cornerRadius: 10,
                        style: .continuous
                    )
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(report.processName) Crash")
                        .font(.body.weight(.medium))
                    Text(formatted(report.capturedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Process \(report.processIdentifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 9)
        }
        .padding(.horizontal, 14)
        .tint(.secondary)
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}

private struct RecentActivityEntryDetails: View {
    let entry: LaunchHistoryEntry
    let presentation: LaunchHistoryEntryPresentation
    let crashReport: ApplicationCrashReport?
    let canReopen: Bool
    let openCrashReport: (ApplicationCrashReport) -> Void
    let reopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(
                alignment: .leading,
                horizontalSpacing: 12,
                verticalSpacing: 5
            ) {
                RecentActivityDetailRow(
                    "Status",
                    value: presentation.statusLabel
                )
                if let processIdentifier = entry.processIdentifier {
                    RecentActivityDetailRow(
                        "Process",
                        value: String(processIdentifier)
                    )
                }
                RecentActivityDetailRow(
                    "Requested",
                    value: formatted(entry.requestedAt)
                )
                if let startedAt = entry.startedAt {
                    RecentActivityDetailRow(
                        "Opened",
                        value: formatted(startedAt)
                    )
                }
                if let endedAt = entry.endedAt {
                    RecentActivityDetailRow(
                        "Ended",
                        value: formatted(endedAt)
                    )
                }
                if let duration = presentation.durationLabel {
                    RecentActivityDetailRow("Duration", value: duration)
                }
            }

            if let crashReport {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        crashSummary(crashReport),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)

                    if let reason = crashReport.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                if let crashReport {
                    Button("Open Crash Report") {
                        openCrashReport(crashReport)
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button("Open Again") {
                    reopen()
                }
                .controlSize(.small)
                .disabled(!canReopen)
            }
        }
        .padding(.leading, 48)
        .padding(.bottom, 12)
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }

    private func crashSummary(
        _ report: ApplicationCrashReport
    ) -> String {
        [report.exceptionType, report.signal]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nonempty
            ?? String(localized: "Crash report available")
    }
}

private struct RecentActivityDetailRow: View {
    let label: LocalizedStringKey
    let value: String

    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

private extension String {
    var nonempty: String? {
        isEmpty ? nil : self
    }
}
