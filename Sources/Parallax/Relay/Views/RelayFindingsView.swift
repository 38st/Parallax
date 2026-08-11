import SwiftUI

private enum RelayFindingFilter: String, CaseIterable, Identifiable {
    case all
    case open
    case resolved
    case waived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .open: String(localized: "Open")
        case .resolved: String(localized: "Resolved")
        case .waived: String(localized: "Waived")
        }
    }
}

struct RelayFindingsView: View {
    let findings: [RelayFindingPresentation]

    @State private var filter: RelayFindingFilter = .open

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                RelaySectionHeader(
                    String(localized: "Findings"),
                    detail: String(
                        localized:
                            "Stable findings remain attached to every rejection and remediation attempt."
                    )
                )
                Spacer()
                Picker("Finding Status", selection: $filter) {
                    ForEach(RelayFindingFilter.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            if filteredFindings.isEmpty {
                RelayEmptySection(
                    title: emptyTitle,
                    systemImage: "checkmark.seal",
                    description: emptyDescription
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredFindings) { finding in
                        RelayFindingRow(finding: finding)
                    }
                }
            }
        }
    }

    private var filteredFindings: [RelayFindingPresentation] {
        findings.filter { finding in
            switch filter {
            case .all: true
            case .open: finding.status == .open
            case .resolved: finding.status == .resolved
            case .waived: finding.status == .waived
            }
        }
        .sorted { lhs, rhs in
            if lhs.status == .open, rhs.status != .open { return true }
            if rhs.status == .open, lhs.status != .open { return false }
            if lhs.severity.rawValue != rhs.severity.rawValue {
                return lhs.severity.rawValue < rhs.severity.rawValue
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: String(localized: "No Findings Recorded")
        case .open: String(localized: "No Open Findings")
        case .resolved: String(localized: "No Resolved Findings")
        case .waived: String(localized: "No Waived Findings")
        }
    }

    private var emptyDescription: String {
        String(
            localized:
                "Finding status is only one part of the completion contract. Review evidence and delivery separately."
        )
    }
}

private struct RelayFindingRow: View {
    let finding: RelayFindingPresentation

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Text(finding.detail)
                    .font(.callout)
                    .textSelection(.enabled)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    RelayLabeledValue(
                        label: String(localized: "Owner stage"),
                        value: finding.ownerStage
                    )
                    RelayLabeledValue(
                        label: String(localized: "Attempt"),
                        value: finding.attemptLabel
                    )
                    RelayLabeledValue(
                        label: String(localized: "Evidence"),
                        value: finding.evidenceIDs.isEmpty
                            ? String(localized: "None recorded")
                            : finding.evidenceIDs.joined(separator: ", "),
                        isMonospaced: true
                    )
                }

                if let resolution = finding.resolution {
                    Label(resolution, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if finding.status == .waived {
                    Label(
                        "Waived by an explicit human decision; the risk remains in the completion record.",
                        systemImage: "person.badge.key"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(finding.severity.label)
                    .font(.caption.bold())
                    .foregroundStyle(relayColor(for: finding.severity.tone))
                    .frame(minWidth: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .font(.body.weight(.medium))
                    Text(
                        verbatim:
                            "\(finding.id) · \(finding.ownerStage)"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(finding.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                verbatim:
                    "\(finding.id), severity \(finding.severity.label), \(finding.title), \(finding.status.label), owner \(finding.ownerStage)"
            )
        )
        .accessibilityIdentifier(
            RelayAccessibilityIdentifier.finding(finding.id)
        )
    }
}
