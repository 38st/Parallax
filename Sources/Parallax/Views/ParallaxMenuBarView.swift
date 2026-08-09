import AppKit
import SwiftUI

struct MenuBarRunningApplicationGroup:
    Identifiable,
    Equatable,
    Sendable
{
    let application: ManagedApplication
    let instances: [ManagedApplicationInstance]

    var id: ManagedApplication.ID {
        application.id
    }
}

struct ParallaxMenuBarLabel: View {
    @Bindable var store: LibraryStore
    let libraryChanges: LibraryChangeBroadcaster

    @State private var refreshRevision: UInt = 0

    var body: some View {
        let count = instanceCount

        HStack(spacing: 4) {
            Image(
                systemName:
                    count > 0
                    ? "square.stack.3d.up.fill"
                    : "square.stack.3d.up"
            )
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            count > 0
                ? Text(
                    String(
                        localized:
                            "Parallax, \(count) running instances"
                    )
                )
                : Text("Parallax, no running instances")
        )
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            )
        ) { _ in
            refresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { _ in
            refresh()
        }
        .onChange(of: libraryChanges.latestEvent) {
            _, event in
            guard
                let event,
                event.sourceSceneID != store.sceneID
            else { return }
            store.reloadFromSharedRepository()
            refresh()
        }
    }

    private var instanceCount: Int {
        _ = refreshRevision
        return store.applications.reduce(into: 0) {
            count, application in
            count += store.runningApplicationInstances(
                for: application
            ).count
        }
    }

    private func refresh() {
        refreshRevision &+= 1
    }
}

struct ParallaxMenuBarView: View {
    @Bindable var store: LibraryStore
    let settings: AppSettings

    @Environment(\.openWindow) private var openWindow
    @State private var refreshRevision: UInt = 0
    @State private var expandedApplicationIDs:
        Set<ManagedApplication.ID> = []

    var body: some View {
        let groups = runningGroups
        let count = groups.reduce(into: 0) {
            $0 += $1.instances.count
        }

        VStack(alignment: .leading, spacing: 0) {
            header(instanceCount: count)

            Divider()

            if groups.isEmpty {
                ContentUnavailableView(
                    "No Running Instances",
                    systemImage: "app.dashed",
                    description: Text(
                        "Open a managed space and it will appear here."
                    )
                )
                .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(groups.enumerated()),
                            id: \.element.id
                        ) { index, group in
                            applicationGroup(group)

                            if index < groups.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(
                    height: runningListHeight(for: groups)
                )
            }

            if store.errorMessage != nil
                || store.libraryOperationStatusMessage != nil
            {
                Divider()
                .padding(.top, 2)
                status
            }

            Divider()
            footer
        }
        .frame(width: 430)
        .preferredColorScheme(
            appColorScheme(for: settings.appearance)
        )
        .onAppear {
            store.reloadFromSharedRepository()
            refresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            )
        ) { _ in
            refresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { _ in
            refresh()
        }
        .onChange(of: groups.map(\.id)) {
            _, runningApplicationIDs in
            expandedApplicationIDs.formIntersection(
                runningApplicationIDs
            )
        }
    }

    private func header(instanceCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Running Instances")
                    .font(.headline)
                Text("Show or quit one instance without affecting the others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                String(localized: "\(instanceCount) active"),
                systemImage: "circle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(
                instanceCount > 0
                    ? AnyShapeStyle(.green)
                    : AnyShapeStyle(.secondary)
            )
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Button("Open Parallax") {
                showMainWindow()
            }

            Spacer()

            Button("Quit Parallax") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        if let errorMessage = store.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(errorMessage)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") {
                    store.errorMessage = nil
                }
                .controlSize(.small)
            }
            .padding(12)
        } else if let message =
            store.libraryOperationStatusMessage
        {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") {
                    store.dismissLibraryOperationStatus()
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var runningGroups: [MenuBarRunningApplicationGroup] {
        _ = refreshRevision
        return store.applications.compactMap { application in
            let instances = store.runningApplicationInstances(
                for: application
            )
            guard !instances.isEmpty else {
                return nil
            }
            return MenuBarRunningApplicationGroup(
                application: application,
                instances: instances
            )
        }
    }

    private func applicationGroup(
        _ group: MenuBarRunningApplicationGroup
    ) -> some View {
        DisclosureGroup(
            isExpanded: expansionBinding(for: group.id)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(
                    Array(group.instances.enumerated()),
                    id: \.element.id
                ) { index, instance in
                    instanceRow(
                        instance,
                        application: group.application
                    )

                    if index < group.instances.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(
                    nsImage: NSWorkspace.shared.icon(
                        forFile: group.application.appPath
                    )
                )
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                Text(group.application.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text(
                    String(
                        localized:
                            "\(group.instances.count) running"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 14)
        .tint(.secondary)
    }

    private func instanceRow(
        _ instance: ManagedApplicationInstance,
        application: ManagedApplication
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

            Spacer(minLength: 8)

            Button("Show") {
                _ = store.requestActivate(
                    instance,
                    from: application
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!instance.actionPresentation.canShow)
            .help(
                instance.actionPresentation.canShow
                    ? String(
                        localized:
                            "Bring only process \(instance.processIdentifier) forward"
                    )
                    : instance.actionPresentation.help
            )
            .accessibilityLabel(
                Text(
                    "Show \(instance.displayName), process \(instance.processIdentifier)"
                )
            )
            .accessibilityHint(
                Text(
                    instance.actionPresentation.canShow
                        ? "Other running instances stay open"
                        : instance.actionPresentation.help
                )
            )

            Button("Quit") {
                if store.requestQuit(
                    instance,
                    from: application
                ) {
                    refresh()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!instance.actionPresentation.canQuit)
            .help(
                instance.actionPresentation.canQuit
                    ? String(
                        localized:
                            "Ask only process \(instance.processIdentifier) to quit"
                    )
                    : instance.actionPresentation.help
            )
            .accessibilityLabel(
                Text(
                    "Quit \(instance.displayName), process \(instance.processIdentifier)"
                )
            )
            .accessibilityHint(
                instance.actionPresentation.canQuit
                    ? Text("Other running instances stay open")
                    : Text(instance.actionPresentation.help)
            )
        }
        .padding(.leading, 8)
        .padding(.vertical, 10)
    }

    private func expansionBinding(
        for applicationID: ManagedApplication.ID
    ) -> Binding<Bool> {
        Binding(
            get: {
                expandedApplicationIDs.contains(applicationID)
            },
            set: { isExpanded in
                if isExpanded {
                    expandedApplicationIDs.insert(applicationID)
                } else {
                    expandedApplicationIDs.remove(applicationID)
                }
            }
        )
    }

    private func runningListHeight(
        for groups: [MenuBarRunningApplicationGroup]
    ) -> CGFloat {
        let applicationRows = groups.count
        let instanceRows = groups.reduce(into: 0) {
            count, group in
            guard expandedApplicationIDs.contains(group.id) else {
                return
            }
            count += group.instances.count
        }
        let naturalHeight =
            CGFloat(applicationRows * 44)
            + CGFloat(instanceRows * 58)
            + CGFloat(max(0, groups.count - 1))
        return min(max(naturalHeight, 44), 440)
    }

    private func instanceDetail(
        _ instance: ManagedApplicationInstance
    ) -> String {
        switch instance.controlPresentation {
        case .verifiedParallaxInstance:
            return String(
                localized:
                    "Parallax space · Process \(instance.processIdentifier)"
            )
        case .outsideParallax:
            return String(
                localized:
                    "Outside Parallax · Informational only · Process \(instance.processIdentifier)"
            )
        case .verificationUnavailable:
            return instance.controlPresentation.detailLabel
                + " · "
                + String(instance.processIdentifier)
        }
    }

    private func showMainWindow() {
        if let window = NSApp.windows.first(where: {
            $0.title == "Parallax" && $0.canBecomeMain
        }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        refreshRevision &+= 1
    }
}
