import AppKit
import SwiftUI

struct ApplicationHeaderView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication

    @State private var isShowingSettings = false
    @State private var isShowingRunningInstances = false
    @State private var isShowingRecentActivity = false
    @State private var instanceRefreshRevision: UInt = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(
                nsImage: NSWorkspace.shared.icon(
                    forFile: application.appPath
                )
            )
            .resizable()
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            Text(application.displayName)
                .font(.title2.bold())
                .lineLimit(1)

            Spacer()

            Button {
                isShowingRecentActivity.toggle()
            } label: {
                Label(
                    "History",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .buttonStyle(.bordered)
            .help(
                "Review recent \(application.displayName) activity and crash reports"
            )
            .accessibilityHint(
                Text(
                    "Shows when spaces opened, closed, failed, or crashed"
                )
            )
            .accessibilityIdentifier(
                "application.recent-activity.\(application.id.uuidString.lowercased())"
            )
            .popover(
                isPresented: $isShowingRecentActivity,
                arrowEdge: .bottom
            ) {
                RecentActivityView(
                    store: store,
                    application: application
                )
            }

            if !runningInstances.isEmpty {
                Button {
                    isShowingRunningInstances.toggle()
                } label: {
                    Label(
                        String(
                            localized:
                                "\(runningInstances.count) Running"
                        ),
                        systemImage: "square.stack.3d.up.fill"
                    )
                }
                .buttonStyle(.bordered)
                .help("Manage running \(application.displayName) instances")
                .accessibilityHint(
                    Text(
                        "Show each running instance and quit only the one you choose"
                    )
                )
                .accessibilityIdentifier(
                    "application.running-instances.\(application.id.uuidString.lowercased())"
                )
                .popover(
                    isPresented: $isShowingRunningInstances,
                    arrowEdge: .bottom
                ) {
                    RunningApplicationInstancesView(
                        applicationName: application.displayName,
                        instances: runningInstances,
                        settings: store.settings
                    ) { instance in
                        if store.requestQuit(
                            instance,
                            from: application
                        ) {
                            instanceRefreshRevision &+= 1
                        }
                    }
                }
            }

            Button("App Settings…") {
                isShowingSettings = true
            }
            .accessibilityHint(
                Text("Edit this app’s name, type, location, and storage")
            )
            .accessibilityIdentifier(
                "application.settings.\(application.id.uuidString.lowercased())"
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(
            minWidth: 0,
            maxWidth: .infinity,
            alignment: .leading
        )
        .sheet(isPresented: $isShowingSettings) {
            ApplicationSettingsView(
                store: store,
                application: application
            )
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            )
        ) { _ in
            instanceRefreshRevision &+= 1
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { _ in
            instanceRefreshRevision &+= 1
        }
    }

    private var runningInstances:
        [ManagedApplicationInstance]
    {
        _ = instanceRefreshRevision
        return store.runningApplicationInstances(for: application)
    }
}

private struct RunningApplicationInstancesView: View {
    let applicationName: String
    let instances: [ManagedApplicationInstance]
    let settings: AppSettings
    let requestQuit: (ManagedApplicationInstance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running Instances")
                        .font(.headline)
                    Text(
                        "Each space has a distinct color and symbol."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Label(
                    String(localized: "\(instances.count) active"),
                    systemImage: "circle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .accessibilityLabel(
                    Text(
                        String(
                            localized:
                                "\(instances.count) running instances"
                        )
                    )
                )
            }
            .padding(14)

            Divider()

            if instances.isEmpty {
                ContentUnavailableView(
                    "No Running Instances",
                    systemImage: "app.dashed"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(instances.enumerated()),
                        id: \.element.id
                    ) { index, instance in
                        instanceRow(instance)
                        if index < instances.count - 1 {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .frame(width: 420)
    }

    private func instanceRow(
        _ instance: ManagedApplicationInstance
    ) -> some View {
        HStack(spacing: 12) {
            ProfileInstanceIdentityPicker(
                settings: settings,
                profileID: instance.profileID,
                profileName: instance.displayName
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(instanceDetail(instance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Button("Quit") {
                requestQuit(instance)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(
                "Ask only process \(instance.processIdentifier) to quit"
            )
            .accessibilityLabel(
                Text(
                    "Quit \(instance.displayName), process \(instance.processIdentifier)"
                )
            )
            .accessibilityHint(
                Text("Other running instances stay open")
            )
            .accessibilityIdentifier(
                "application.instance.quit.\(instance.processIdentifier)"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func instanceDetail(
        _ instance: ManagedApplicationInstance
    ) -> String {
        instance.isTrackedSpace
            ? String(
                localized:
                    "\(applicationName) · Process \(instance.processIdentifier)"
            )
            : String(
                localized:
                    "Outside Parallax · Process \(instance.processIdentifier)"
            )
    }
}
