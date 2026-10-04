import SwiftUI

struct WorkspaceSettingsView: View {
    @Bindable var store: LibraryStore
    @Bindable var corporateStore: CorporateUsageStore
    @Bindable var operations: CorporateAccountOperationCoordinator
    @State private var showsUsage = false
    @State private var maintenanceApplication: ManagedApplication?

    var body: some View {
        Form {
            Section("Preferences") {
                SettingsLink { Label("General, Spaces & Appearance", systemImage: "gearshape") }
            }
            Section("Usage connections") {
                Text("Optional CLI connections provide usage details. Desktop sign-ins are managed inside each app.")
                    .foregroundStyle(.secondary)
                Button("Manage Usage Connections…") { showsUsage = true }
            }
            Section("Import & Export") {
                Text("Configuration exports contain settings, not conversations or provider credentials.")
                    .foregroundStyle(.secondary)
                Button("Import Library...") { store.importLibrary() }
                Button("Export Library Metadata...") { store.exportPortable(.libraryMetadata) }
                    .disabled(!store.canExportPortable(.libraryMetadata))
                Button("Export Settings and Templates...") { store.exportPortable(.settingsAndTemplates) }
                    .disabled(!store.canExportPortable(.settingsAndTemplates))
                Button("Export Portable Configuration...") { store.exportPortable(.portableConfiguration) }
                    .disabled(!store.canExportPortable(.portableConfiguration))
                Button("Undo Last Library Replacement") { store.undoLastImportReplacement() }
                    .disabled(!store.canUndoLastImportReplacement)
            }
            Section("Storage & Maintenance") {
                Text("Choose an app for storage settings. Use a space’s actions to keep, archive, or delete its data when removing it.")
                    .foregroundStyle(.secondary)
                ForEach(store.applications) { application in
                    Button { maintenanceApplication = application } label: {
                        HStack {
                            Text(application.displayName)
                            Spacer()
                            Text("App Settings…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SpaceOperationStatusView(store: store)
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(item: $maintenanceApplication) { application in
            ApplicationSettingsView(store: store, application: application)
                .safeAreaInset(edge: .bottom) { SpaceOperationStatusView(store: store).padding() }
        }
        .sheet(isPresented: $showsUsage) {
            VStack {
                HStack { Spacer(); Button("Done") { showsUsage = false } }.padding()
                SpaceOperationStatusView(store: store).padding(.horizontal)
                CorporateAccountTrackerContent(store: corporateStore, operationCoordinator: operations,
                    libraryStore: store, recreateCodexSpaces: { store.synchronizeCodexAccountSpaces(accounts: corporateStore.trackedAccounts, recreateRemovedSpaces: true) })
            }.frame(minWidth: 700, minHeight: 560)
        }
    }
}

struct WorkspaceActivityView: View {
    @Bindable var store: LibraryStore
    @Bindable var corporateStore: CorporateUsageStore
    @State private var selectedApplication: ManagedApplication?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Activity").font(.largeTitle).padding([.top, .horizontal])
            ScrollView(.horizontal) {
                HStack {
                    ForEach(store.applications) { application in
                        Button(application.displayName) { selectedApplication = application }
                    }
                }.padding(.horizontal)
            }
            CorporateLiveAccountActivityContent(store: corporateStore)
        }
        .sheet(item: $selectedApplication) { application in
            RecentActivityView(store: store, application: application)
                .safeAreaInset(edge: .bottom) { SpaceOperationStatusView(store: store).padding() }
        }
    }
}
