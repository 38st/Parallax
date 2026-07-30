import AppKit
import SwiftUI

enum LaunchHistoryPresentationTone: Sendable, Equatable {
    case neutral
    case active
    case warning
    case failure
}

struct LaunchHistoryEntryPresentation: Sendable, Equatable {
    let statusLabel: String
    let timeLabel: String
    let durationLabel: String?
    let systemImageName: String
    let tone: LaunchHistoryPresentationTone

    init(
        entry: LaunchHistoryEntry,
        crashReport: ApplicationCrashReport? = nil,
        now: Date = Date(),
        locale: Locale = .current
    ) {
        if crashReport != nil {
            statusLabel = String(localized: "Crashed")
            systemImageName = "exclamationmark.triangle.fill"
            tone = .failure
        } else {
            switch entry.state {
            case .opening:
                statusLabel = String(localized: "Opening")
                systemImageName = "arrow.up.forward.app.fill"
                tone = .warning
            case .running:
                statusLabel = String(localized: "Running")
                systemImageName = "circle.fill"
                tone = .active
            case .closed:
                if entry.terminationDisposition == .unexpected {
                    statusLabel = String(
                        localized: "Ended Unexpectedly"
                    )
                    systemImageName =
                        "exclamationmark.triangle.fill"
                    tone = .failure
                } else {
                    statusLabel = String(localized: "Closed")
                    systemImageName = "checkmark.circle"
                    tone = .neutral
                }
            case .failed:
                statusLabel = String(localized: "Couldn’t Open")
                systemImageName = "xmark.octagon.fill"
                tone = .failure
            }
        }

        let activityDate = entry.endedAt
            ?? entry.startedAt
            ?? entry.requestedAt
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .named
        timeLabel = relativeFormatter.localizedString(
            for: activityDate,
            relativeTo: now
        )

        if let startedAt = entry.startedAt {
            let end = entry.endedAt ?? now
            durationLabel = Self.durationLabel(
                max(0, end.timeIntervalSince(startedAt)),
                locale: locale
            )
        } else {
            durationLabel = nil
        }
    }

    private static func durationLabel(
        _ duration: TimeInterval,
        locale: Locale
    ) -> String {
        guard duration >= 60 else {
            return String(localized: "Less than a minute")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: duration)
            ?? String(localized: "Less than a minute")
    }
}

struct RecentActivityView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication

    @State private var crashReports:
        [UUID: ApplicationCrashReport] = [:]
    @State private var recentCrashReports:
        [ApplicationCrashReport] = []
    @State private var expandedRequestIDs: Set<UUID> = []
    @State private var expandedCrashReportURLs: Set<URL> = []
    @State private var isConfirmingClear = false

    private let crashReportLocator = ApplicationCrashReportLocator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error =
                store.launchHistoryPersistenceErrorMessage
            {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(14)
                Divider()
            }

            if entries.isEmpty && recentCrashReports.isEmpty {
                ContentUnavailableView(
                    "No Recent Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Spaces opened from Parallax will appear here."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !entries.isEmpty {
                            sectionHeader("Parallax Activity")
                            ForEach(
                                Array(entries.enumerated()),
                                id: \.element.id
                            ) { index, entry in
                                activityRow(entry)
                                if index < entries.count - 1 {
                                    Divider()
                                        .padding(.leading, 62)
                                }
                            }
                        }

                        if !unlinkedCrashReports.isEmpty {
                            if !entries.isEmpty {
                                Divider()
                            }
                            sectionHeader(
                                "Other macOS Crash Reports"
                            )
                            ForEach(
                                Array(
                                    unlinkedCrashReports.enumerated()
                                ),
                                id: \.element.id
                            ) { index, report in
                                crashReportRow(report)
                                if index
                                    < unlinkedCrashReports.count - 1
                                {
                                    Divider()
                                        .padding(.leading, 62)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 520)
        .onAppear {
            store.refreshLaunchHistory()
        }
        .task(id: entries) {
            let snapshot = entries
            let result = await Task.detached {
                CrashReportLoadResult(
                    matched: crashReportLocator.reports(
                        matching: snapshot
                    ),
                    recent: crashReportLocator.recentReports(
                        bundleIdentifier:
                            application.bundleIdentifier,
                        processName: application.displayName
                    )
                )
            }.value
            crashReports = result.matched
            recentCrashReports = result.recent
        }
        .confirmationDialog(
            "Clear Recent Activity?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Activity", role: .destructive) {
                store.clearLaunchHistory(for: application)
                crashReports = [:]
                expandedRequestIDs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes Parallax’s activity list for \(application.displayName). It does not delete spaces, app data, or macOS crash reports."
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent Activity")
                    .font(.headline)
                Text(
                    "Open history and crash reports for this app."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Export Sanitized Support Bundle…") {
                    store.exportSanitizedSupportBundle(
                        for: application,
                        crashReports: crashReports
                    )
                }

                Button(
                    "Clear Recent Activity…",
                    role: .destructive
                ) {
                    isConfirmingClear = true
                }
                .disabled(entries.isEmpty)

                Button("Show Crash Reports in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath:
                            crashReportLocator
                                .diagnosticReportsURL.path
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Activity options")
            .accessibilityLabel(Text("Activity options"))
        }
        .padding(14)
    }

    private func activityRow(
        _ entry: LaunchHistoryEntry
    ) -> some View {
        let crashReport = crashReports[entry.requestID]
        let presentation = LaunchHistoryEntryPresentation(
            entry: entry,
            crashReport: crashReport
        )

        return DisclosureGroup(
            isExpanded: Binding(
                get: {
                    expandedRequestIDs.contains(entry.requestID)
                },
                set: { isExpanded in
                    if isExpanded {
                        expandedRequestIDs.insert(entry.requestID)
                    } else {
                        expandedRequestIDs.remove(entry.requestID)
                    }
                }
            )
        ) {
            activityDetails(
                entry,
                presentation: presentation,
                crashReport: crashReport
            )
        } label: {
            HStack(spacing: 12) {
                ProfileInstanceIdentityMark(
                    identity:
                        store.settings.profileVisualIdentity(
                            for: entry.profileID
                        ),
                    isTrackedSpace: true
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.profileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Image(
                            systemName:
                                presentation.systemImageName
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            color(for: presentation.tone)
                        )
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
        }
        .padding(.horizontal, 14)
        .tint(.secondary)
        .accessibilityIdentifier(
            "launch-history.entry.\(entry.requestID.uuidString.lowercased())"
        )
    }

    private func crashReportRow(
        _ report: ApplicationCrashReport
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: {
                    expandedCrashReportURLs.contains(
                        report.fileURL
                    )
                },
                set: { isExpanded in
                    if isExpanded {
                        expandedCrashReportURLs.insert(
                            report.fileURL
                        )
                    } else {
                        expandedCrashReportURLs.remove(
                            report.fileURL
                        )
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 12,
                    verticalSpacing: 5
                ) {
                    detailRow(
                        "Process",
                        value: String(
                            report.processIdentifier
                        )
                    )
                    detailRow(
                        "Crashed",
                        value: formatted(report.capturedAt)
                    )
                    if let launchedAt = report.launchedAt {
                        detailRow(
                            "Launched",
                            value: formatted(launchedAt)
                        )
                    }
                    if let exceptionType =
                        report.exceptionType
                    {
                        detailRow(
                            "Exception",
                            value: exceptionType
                        )
                    }
                    if let signal = report.signal {
                        detailRow("Signal", value: signal)
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
                        NSWorkspace.shared.open(
                            report.fileURL
                        )
                    }
                    .controlSize(.small)
                }
            }
            .padding(.leading, 48)
            .padding(.bottom, 12)
        } label: {
            HStack(spacing: 12) {
                Image(
                    systemName:
                        "exclamationmark.triangle.fill"
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

    private func activityDetails(
        _ entry: LaunchHistoryEntry,
        presentation: LaunchHistoryEntryPresentation,
        crashReport: ApplicationCrashReport?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(
                alignment: .leading,
                horizontalSpacing: 12,
                verticalSpacing: 5
            ) {
                detailRow(
                    "Status",
                    value: presentation.statusLabel
                )
                if let processIdentifier =
                    entry.processIdentifier
                {
                    detailRow(
                        "Process",
                        value: String(processIdentifier)
                    )
                }
                detailRow(
                    "Requested",
                    value: formatted(entry.requestedAt)
                )
                if let startedAt = entry.startedAt {
                    detailRow(
                        "Opened",
                        value: formatted(startedAt)
                    )
                }
                if let endedAt = entry.endedAt {
                    detailRow(
                        "Ended",
                        value: formatted(endedAt)
                    )
                }
                if let duration = presentation.durationLabel {
                    detailRow("Duration", value: duration)
                }
            }

            if let crashReport {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        crashSummary(crashReport),
                        systemImage:
                            "exclamationmark.triangle.fill"
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
                        NSWorkspace.shared.open(
                            crashReport.fileURL
                        )
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button("Open Again") {
                    _ = store.reopen(
                        entry,
                        from: application
                    )
                }
                .controlSize(.small)
                .disabled(!canReopen(entry))
            }
        }
        .padding(.leading, 48)
        .padding(.bottom, 12)
    }

    private func detailRow(
        _ label: LocalizedStringKey,
        value: String
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private var entries: [LaunchHistoryEntry] {
        store.launchHistory(for: application)
    }

    private var unlinkedCrashReports:
        [ApplicationCrashReport]
    {
        let linkedURLs = Set(
            crashReports.values.map(\.fileURL)
        )
        return recentCrashReports.filter {
            !linkedURLs.contains($0.fileURL)
        }
    }

    private func sectionHeader(
        _ title: LocalizedStringKey
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 3)
    }

    private func canReopen(
        _ entry: LaunchHistoryEntry
    ) -> Bool {
        application.profiles.contains {
            $0.id == entry.profileID
                && $0.storageID == entry.profileStorageID
        }
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

private extension String {
    var nonempty: String? {
        isEmpty ? nil : self
    }
}

private struct CrashReportLoadResult: Sendable {
    let matched: [UUID: ApplicationCrashReport]
    let recent: [ApplicationCrashReport]
}
