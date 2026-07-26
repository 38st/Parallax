import AppKit
import SwiftUI

func appColorScheme(
    for appearance: AppAppearance
) -> ColorScheme? {
    switch appearance {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
}

@MainActor
private final class ParallaxSharedServices {
    let profileActivityRegistry: ProfileActivityRegistry

    init(fileSystem: any FileSystem = LocalFileSystem()) {
        if let applicationSupportURL =
            try? fileSystem.applicationSupportURL(create: true),
           let registry = try? ProfileActivityRegistry(
               applicationSupportURL: applicationSupportURL
           )
        {
            profileActivityRegistry = registry
        } else {
            profileActivityRegistry = ProfileActivityRegistry()
        }
    }
}

private struct ParallaxStoreFocusedValueKey: FocusedValueKey {
    typealias Value = LibraryStore
}

private extension FocusedValues {
    var parallaxStore: LibraryStore? {
        get { self[ParallaxStoreFocusedValueKey.self] }
        set { self[ParallaxStoreFocusedValueKey.self] = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct ParallaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.parallaxStore) private var focusedStore
    @State private var settings: AppSettings
    @State private var libraryChanges: LibraryChangeBroadcaster
    private let sharedServices: ParallaxSharedServices

    init() {
        let settings = AppSettings()
        _settings = State(wrappedValue: settings)
        _libraryChanges = State(
            wrappedValue: LibraryChangeBroadcaster()
        )
        sharedServices = ParallaxSharedServices()
    }

    var body: some Scene {
        WindowGroup("Parallax", id: "main") {
            ParallaxSceneRoot(
                settings: settings,
                sharedServices: sharedServices,
                libraryChanges: libraryChanges
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Add Application") {
                    focusedStore?.beginAddingApplication()
                }
                .disabled(focusedStore == nil)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            CommandMenu("Library") {
                Button("Import Library...") {
                    focusedStore?.importLibrary()
                }
                .disabled(focusedStore == nil)

                Button("Export Library Metadata...") {
                    focusedStore?.exportPortable(.libraryMetadata)
                }
                .disabled(focusedStore == nil)

                Button("Export Settings and Templates...") {
                    focusedStore?.exportPortable(.settingsAndTemplates)
                }
                .disabled(focusedStore == nil)

                Button("Export Portable Configuration...") {
                    focusedStore?.exportPortable(.portableConfiguration)
                }
                .disabled(focusedStore == nil)

                Divider()

                Button("Undo Last Library Replacement") {
                    focusedStore?.undoLastImportReplacement()
                }
                .disabled(
                    focusedStore?.canUndoLastImportReplacement != true
                )
            }
        }

        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(
                    appColorScheme(for: settings.appearance)
                )
        }
    }

}

private struct ParallaxSceneRoot: View {
    @State private var store: LibraryStore
    let settings: AppSettings
    let libraryChanges: LibraryChangeBroadcaster

    init(
        settings: AppSettings,
        sharedServices: ParallaxSharedServices,
        libraryChanges: LibraryChangeBroadcaster
    ) {
        self.settings = settings
        self.libraryChanges = libraryChanges
        let sceneID = UUID()
        _store = State(
            wrappedValue: LibraryStore(
                profileActivityRegistry:
                    sharedServices.profileActivityRegistry,
                settings: settings,
                sceneID: sceneID,
                libraryChangeBroadcaster: libraryChanges
            )
        )
    }

    var body: some View {
        ContentView(store: store)
            .frame(minWidth: 980, minHeight: 620)
            .preferredColorScheme(
                appColorScheme(for: settings.appearance)
            )
            .focusedSceneValue(\.parallaxStore, store)
            .onChange(of: libraryChanges.latestEvent) {
                _, event in
                guard
                    let event,
                    event.sourceSceneID != store.sceneID
                else { return }
                store.reloadFromSharedRepository()
            }
            .alert(
                "Launch profile?",
                isPresented: $store.isShowingLaunchConfirmation
            ) {
                Button("Launch", role: .none) {
                    store.confirmLaunch()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelLaunch()
                }
            } message: {
                if
                    let applicationName =
                        store.pendingLaunchApplicationName,
                    let profileName =
                        store.pendingLaunchProfileName
                {
                    Text(
                        "Launch “\(profileName)” in “\(applicationName)”?"
                    )
                } else {
                    Text("Launch the selected profile?")
                }
            }
            .alert(
                "Import Library",
                isPresented: $store.isShowingImportChoice
            ) {
                Button("Merge with Existing") {
                    store.confirmImport(replacing: false)
                }
                Button("Replace Existing", role: .destructive) {
                    store.confirmImport(replacing: true)
                }
                Button("Cancel", role: .cancel) {
                    store.cancelImport()
                }
            } message: {
                Text(
                    store.pendingImportSummary?.message
                        ?? String(
                            localized:
                                "Merge requires an explicit choice for every conflict. Replace creates a verified undo backup and preserves profile data."
                        )
                )
            }
            .sheet(
                isPresented:
                    $store.isShowingImportConflictResolution
            ) {
                LibraryImportConflictResolutionView(store: store)
            }
            .sheet(
                isPresented:
                    $store.isShowingImportedLaunchReview
            ) {
                ImportedLaunchReviewView(store: store)
            }
            .sheet(
                isPresented:
                    $store
                        .isShowingApplicationRemovalConfirmation
            ) {
                ApplicationRemovalConfirmationView(store: store)
            }
            .alert(
                "Launch malformed configuration?",
                isPresented:
                    $store.isShowingLaunchDiagnosticOverride
            ) {
                Button("Launch Anyway") {
                    store.confirmLaunchDiagnosticOverride()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelLaunchDiagnosticOverride()
                }
            } message: {
                Text(
                    store.pendingLaunchDiagnosticMessage
                        ?? String(
                            localized:
                                "The launch configuration has parsing errors."
                        )
                )
            }
            .alert(
                "Launch this profile concurrently?",
                isPresented:
                    $store.isShowingConcurrentLaunchOverride
            ) {
                Button("Launch Anyway", role: .destructive) {
                    store.confirmConcurrentLaunchOverride()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelConcurrentLaunchOverride()
                }
            } message: {
                Text(
                    "Another process is using this profile’s storage. Running both at once can corrupt profile data or destabilize both applications. Continue only if you accept that risk."
                )
            }
            .alert(
                store.pendingDestructiveActionPresentation?.title
                    ?? String(localized: "Confirm Action"),
                isPresented:
                    $store.isShowingDestructiveActionConfirmation
            ) {
                Button("Continue", role: .destructive) {
                    store.confirmDestructiveAction()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelDestructiveAction()
                }
            } message: {
                Text(
                    store.pendingDestructiveActionPresentation?
                        .message
                        ?? String(
                            localized:
                                "Review the exact profile-data target before continuing."
                        )
                )
            }
            .alert(
                "Profile data is active",
                isPresented:
                    $store.isShowingDestructiveExpertOverride
            ) {
                Button(
                    "Accept Risk and Continue",
                    role: .destructive
                ) {
                    store.confirmDestructiveExpertOverride()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelDestructiveAction()
                }
            } message: {
                Text(store.destructiveExpertOverrideWarning)
            }
            .alert(
                "Update Application Location?",
                isPresented:
                    $store.isShowingApplicationRelinkConfirmation
            ) {
                Button("Update Location") {
                    store.confirmApplicationRelink()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelApplicationRelink()
                }
            } message: {
                Text(
                    store.pendingApplicationRelinkMessage
                        ?? String(
                            localized:
                                "Review the verified application location before updating the library."
                        )
                )
            }
    }

}
