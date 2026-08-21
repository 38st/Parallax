import AppKit
import Darwin
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
        if ProcessInfo.processInfo.arguments.contains(
            PackagedRuntimeResources.smokeTestArgument
        ) {
            do {
                try PackagedRuntimeResources.verify()
                FileHandle.standardOutput.write(
                    Data("Parallax packaged resources: OK\n".utf8)
                )
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(
                    Data(
                        "Parallax packaged resources: \(error.localizedDescription)\n"
                            .utf8
                    )
                )
                exit(EXIT_FAILURE)
            }
        }
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
    @State private var menuBarStore: LibraryStore
    private let libraryStoreFactory: ParallaxLibraryStoreFactory

    init() {
        let composition = ParallaxAppComposition()
        _settings = State(wrappedValue: composition.settings)
        _libraryChanges = State(
            wrappedValue: composition.libraryChanges
        )
        _menuBarStore = State(
            wrappedValue: composition.makeLibraryStore()
        )
        libraryStoreFactory = composition.libraryStoreFactory
    }

    var body: some Scene {
        WindowGroup("Parallax", id: "main") {
            ParallaxSceneRoot(
                libraryStoreFactory: libraryStoreFactory
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Choose an App…") {
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
                .disabled(
                    !settings.canProvideVerifiedSettings
                        || focusedStore?.canExportPortable(
                            .settingsAndTemplates
                        ) != true
                )

                Button("Export Portable Configuration...") {
                    focusedStore?.exportPortable(.portableConfiguration)
                }
                .disabled(
                    !settings.canProvideVerifiedSettings
                        || focusedStore?.canExportPortable(
                            .portableConfiguration
                        ) != true
                )

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

        MenuBarExtra {
            ParallaxMenuBarView(
                store: menuBarStore,
                settings: settings
            )
        } label: {
            ParallaxMenuBarLabel(
                store: menuBarStore,
                libraryChanges: libraryChanges
            )
        }
        .menuBarExtraStyle(.window)
    }

}

private struct ParallaxSceneRoot: View {
    @State private var store: LibraryStore
    let settings: AppSettings
    let libraryChanges: LibraryChangeBroadcaster
    let corporateStore: CorporateUsageStore
    let corporateAccountOperationCoordinator:
        CorporateAccountOperationCoordinator

    init(
        libraryStoreFactory: ParallaxLibraryStoreFactory
    ) {
        settings = libraryStoreFactory.settings
        libraryChanges = libraryStoreFactory.libraryChanges
        corporateStore = libraryStoreFactory.sharedServices
            .corporateUsageStore
        corporateAccountOperationCoordinator = libraryStoreFactory
            .sharedServices.corporateAccountOperationCoordinator
        _store = State(
            wrappedValue: libraryStoreFactory.makeStore()
        )
    }

    var body: some View {
        ContentView(
            store: store,
            corporateStore: corporateStore,
            corporateAccountOperationCoordinator:
                corporateAccountOperationCoordinator
        )
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
                "Open space?",
                isPresented: $store.isShowingLaunchConfirmation
            ) {
                Button("Open", role: .none) {
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
                        "Open “\(profileName)” in “\(applicationName)”?"
                    )
                } else {
                    Text("Open the selected space?")
                }
            }
            .alert(
                "Import Library",
                isPresented: Binding(
                    get: { store.isShowingImportChoice },
                    set: { _ in }
                )
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
                isPresented: Binding(
                    get: {
                        store.pendingImportConflictPrompt != nil
                    },
                    set: { isPresented in
                        if !isPresented,
                            store.pendingImportConflictPrompt != nil
                        {
                            store.cancelImport()
                        }
                    }
                )
            ) {
                if let prompt = store.pendingImportConflictPrompt {
                    LibraryImportConflictResolutionView(
                        prompt: prompt,
                        onResolve: { choice, target in
                            store.resolvePendingImportConflict(
                                choice,
                                target: target,
                                expectedPrompt: prompt
                            )
                        },
                        onCancel: store.cancelImport
                    )
                }
            }
            .sheet(
                isPresented:
                    $store.isShowingImportedLaunchReview
            ) {
                if let review = store.pendingImportedLaunchReview {
                    ImportedLaunchReviewView(
                        review: review,
                        onCancel: store.cancelImportedLaunchReview,
                        onApprove: {
                            store.confirmImportedLaunchReview(
                                expectedFingerprint: review.fingerprint
                            )
                        }
                    )
                }
            }
            .sheet(
                isPresented:
                    $store
                        .isShowingApplicationRemovalConfirmation
            ) {
                ApplicationRemovalConfirmationView(store: store)
            }
            .alert(
                "Open malformed configuration?",
                isPresented:
                    $store.isShowingLaunchDiagnosticOverride
            ) {
                Button("Open Anyway") {
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
                "Open this space concurrently?",
                isPresented:
                    $store.isShowingConcurrentLaunchOverride
            ) {
                Button("Open Anyway", role: .destructive) {
                    store.confirmConcurrentLaunchOverride()
                }
                Button("Cancel", role: .cancel) {
                    store.cancelConcurrentLaunchOverride()
                }
            } message: {
                Text(
                    "Another process is using this space’s storage. Running both at once can corrupt its data or destabilize both apps. Continue only if you accept that risk."
                )
            }
            .alert(
                store.pendingDestructiveActionPresentation?.title
                    ?? String(localized: "Confirm Action"),
                isPresented:
                    $store.isShowingDestructiveActionConfirmation
            ) {
                Button("Continue", role: .destructive) {
                    Task {
                        await store.confirmDestructiveActionAsync()
                    }
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
                                "Review the exact space-data target before continuing."
                        )
                )
            }
            .alert(
                "Space data is active",
                isPresented:
                    $store.isShowingDestructiveExpertOverride
            ) {
                Button(
                    "Accept Risk and Continue",
                    role: .destructive
                ) {
                    Task {
                        await store.confirmDestructiveExpertOverrideAsync()
                    }
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
