import AppKit
import SwiftUI

struct RecentActivityView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication

    @State private var model = RecentActivityModel()

    private let crashReportLocator = ApplicationCrashReportLocator()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = store.launchHistoryPersistenceErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(14)
                Divider()
            }

            if entries.isEmpty && model.recentCrashReports.isEmpty {
                ContentUnavailableView(
                    "No Recent Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Spaces opened from Parallax will appear here."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                activityList
            }
        }
        .frame(width: 520, height: 520)
        .onAppear {
            store.refreshLaunchHistory()
        }
        .task(id: loadRequest) {
            await model.reload(for: loadRequest)
        }
        .confirmationDialog(
            "Clear Recent Activity?",
            isPresented: $model.isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Activity", role: .destructive) {
                store.clearLaunchHistory(for: application)
                model.clearParallaxActivity()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes Parallax’s activity list for \(application.displayName). It does not delete spaces, app data, or macOS crash reports."
            )
        }
    }

    private var activityList: some View {
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

                if !model.unlinkedCrashReports.isEmpty {
                    if !entries.isEmpty {
                        Divider()
                    }
                    sectionHeader("Other macOS Crash Reports")
                    ForEach(
                        Array(
                            model.unlinkedCrashReports.enumerated()
                        ),
                        id: \.element.id
                    ) { index, report in
                        crashReportRow(report)
                        if index
                            < model.unlinkedCrashReports.count - 1
                        {
                            Divider()
                                .padding(.leading, 62)
                        }
                    }
                }
            }
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
                        crashReports: model.crashReports
                    )
                }

                Button(
                    "Clear Recent Activity…",
                    role: .destructive
                ) {
                    model.isConfirmingClear = true
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
        RecentActivityEntryRow(
            entry: entry,
            crashReport: model.crashReports[entry.requestID],
            identity: store.settings.profileVisualIdentity(
                for: entry.profileID
            ),
            isExpanded: Binding(
                get: {
                    model.isEntryExpanded(entry.requestID)
                },
                set: { isExpanded in
                    model.setEntryExpanded(
                        isExpanded,
                        requestID: entry.requestID
                    )
                }
            ),
            canReopen: canReopen(entry),
            openCrashReport: { report in
                NSWorkspace.shared.open(report.fileURL)
            },
            reopen: {
                _ = store.reopen(entry, from: application)
            }
        )
    }

    private func crashReportRow(
        _ report: ApplicationCrashReport
    ) -> some View {
        RecentActivityCrashReportRow(
            report: report,
            isExpanded: Binding(
                get: {
                    model.isCrashReportExpanded(report.fileURL)
                },
                set: { isExpanded in
                    model.setCrashReportExpanded(
                        isExpanded,
                        fileURL: report.fileURL
                    )
                }
            ),
            openCrashReport: {
                NSWorkspace.shared.open(report.fileURL)
            }
        )
    }

    private var entries: [LaunchHistoryEntry] {
        store.launchHistory(for: application)
    }

    private var loadRequest: RecentActivityLoadRequest {
        RecentActivityLoadRequest(
            applicationID: application.id,
            bundleIdentifier: application.bundleIdentifier,
            processName: application.displayName,
            entries: entries
        )
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
}
