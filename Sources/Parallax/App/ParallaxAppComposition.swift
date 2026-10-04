import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class ParallaxSharedServices {
    let editorDraftRegistry = ProfileEditorDraftRegistry()
    let mainWindows = ParallaxMainWindowRegistry()
    let profileActivityRegistry: ProfileActivityRegistry
    let launchHistoryStore: LaunchHistoryStore
    let managedAppWorkaroundStore: ManagedAppWorkaroundStore
    let managedAppRecoveryLedger: ManagedAppRecoveryLedger
    let corporateUsageStore: CorporateUsageStore
    let corporateAccountOperationCoordinator:
        CorporateAccountOperationCoordinator
    let profileActivityInitializationError: Error?

    init(
        trustedContainer: TrustedParallaxContainer?,
        applicationSupportInitializationError: Error?,
        containerBootstrapFailure: SettingsRuntimeContainerFailure?,
        corporateUsageStore: CorporateUsageStore? = nil
    ) {
        let accountStore = corporateUsageStore ?? CorporateUsageStore()
        self.corporateUsageStore = accountStore
        corporateAccountOperationCoordinator =
            CorporateAccountOperationCoordinator(store: accountStore)
        corporateAccountOperationCoordinator.startAutomaticRefresh()
        do {
            guard let trustedContainer else {
                let error = applicationSupportInitializationError
                    ?? containerBootstrapFailure
                    ?? CocoaError(.fileNoSuchFile)
                AppLog.general.error(
                    "Failed to initialize the trusted Parallax container: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            let applicationSupportURL = trustedContainer.url
                .deletingLastPathComponent()
            do {
                profileActivityRegistry =
                    try ProfileActivityRegistry(
                        applicationSupportURL: applicationSupportURL
                    )
                profileActivityInitializationError = nil
            } catch {
                profileActivityRegistry = ProfileActivityRegistry()
                profileActivityInitializationError = error
            }
            do {
                launchHistoryStore =
                    try LaunchHistoryStore(
                        trustedContainer: trustedContainer
                    )
            } catch {
                launchHistoryStore = LaunchHistoryStore(
                    persistenceErrorMessage: error.localizedDescription
                )
            }
            do {
                managedAppWorkaroundStore =
                    try ManagedAppWorkaroundStore(
                        trustedContainer: trustedContainer
                    )
            } catch {
                managedAppWorkaroundStore =
                    ManagedAppWorkaroundStore(
                        persistenceErrorMessage:
                            error.localizedDescription
                    )
            }
            do {
                managedAppRecoveryLedger =
                    try ManagedAppRecoveryLedger(
                        trustedContainer: trustedContainer
                    )
            } catch {
                managedAppRecoveryLedger =
                    ManagedAppRecoveryLedger(
                        persistenceErrorMessage:
                            error.localizedDescription
                    )
            }
        } catch {
            profileActivityRegistry = ProfileActivityRegistry()
            profileActivityInitializationError = error
            launchHistoryStore = LaunchHistoryStore(
                persistenceErrorMessage: error.localizedDescription
            )
            managedAppWorkaroundStore =
                ManagedAppWorkaroundStore(
                    persistenceErrorMessage:
                        error.localizedDescription
                )
            managedAppRecoveryLedger =
                ManagedAppRecoveryLedger(
                    persistenceErrorMessage:
                        error.localizedDescription
                )
        }
    }
}

@MainActor
struct ParallaxLibraryStoreFactory {
    typealias StoreBuilder = @MainActor (
        ParallaxSharedServices,
        AppSettings,
        LibraryChangeBroadcaster,
        UUID
    ) -> LibraryStore

    let sharedServices: ParallaxSharedServices
    let settings: AppSettings
    let libraryChanges: LibraryChangeBroadcaster
    private let storeBuilder: StoreBuilder

    init(
        sharedServices: ParallaxSharedServices,
        settings: AppSettings,
        libraryChanges: LibraryChangeBroadcaster,
        storeBuilder: @escaping StoreBuilder = {
            sharedServices,
            settings,
            libraryChanges,
            sceneID in
            LibraryStore(
                profileActivityRegistry:
                    sharedServices.profileActivityRegistry,
                profileActivityBootstrapError:
                    sharedServices.profileActivityInitializationError,
                launchHistoryStore:
                    sharedServices.launchHistoryStore,
                managedAppWorkaroundStore:
                    sharedServices.managedAppWorkaroundStore,
                managedAppRecoveryLedger:
                    sharedServices.managedAppRecoveryLedger,
                settings: settings,
                sceneID: sceneID,
                libraryChangeBroadcaster: libraryChanges
            )
        }
    ) {
        self.sharedServices = sharedServices
        self.settings = settings
        self.libraryChanges = libraryChanges
        self.storeBuilder = storeBuilder
    }

    func makeStore(sceneID: UUID = UUID()) -> LibraryStore {
        let store = storeBuilder(
            sharedServices,
            settings,
            libraryChanges,
            sceneID
        )
        store.sceneCoordinator.editorDraftRegistry = sharedServices.editorDraftRegistry
        return store
    }
}

@MainActor
struct ParallaxAppComposition {
    struct Builders {
        let discoverApplicationSupport: @MainActor () throws -> URL
        let bootstrapSettings:
            @MainActor (URL) -> SettingsRuntimeBootstrapOutcome
        let makeSharedServices:
            @MainActor (
                TrustedParallaxContainer?,
                Error?,
                SettingsRuntimeContainerFailure?
            ) -> ParallaxSharedServices
        let makeLibraryStoreFactory:
            @MainActor (
                ParallaxSharedServices,
                AppSettings,
                LibraryChangeBroadcaster
            ) -> ParallaxLibraryStoreFactory

        static var production: Builders {
            Builders(
                discoverApplicationSupport: {
                    try LocalFileSystem()
                        .applicationSupportURL(create: true)
                },
                bootstrapSettings: { applicationSupportURL in
                    SettingsRuntimeBootstrapper(
                        applicationSupportURL: applicationSupportURL,
                        legacyApplicationIdentifier:
                            Bundle.main.bundleIdentifier
                            ?? "com.parallax.Parallax"
                    ).bootstrapOutcome()
                },
                makeSharedServices: {
                    trustedContainer,
                    error,
                    containerBootstrapFailure in
                    ParallaxSharedServices(
                        trustedContainer: trustedContainer,
                        applicationSupportInitializationError: error,
                        containerBootstrapFailure:
                            containerBootstrapFailure
                    )
                },
                makeLibraryStoreFactory: {
                    sharedServices,
                    settings,
                    libraryChanges in
                    ParallaxLibraryStoreFactory(
                        sharedServices: sharedServices,
                        settings: settings,
                        libraryChanges: libraryChanges
                    )
                }
            )
        }
    }

    let settings: AppSettings
    let libraryChanges: LibraryChangeBroadcaster
    let libraryStoreFactory: ParallaxLibraryStoreFactory

    init(builders: Builders = .production) {
        let applicationSupportURL: URL?
        let applicationSupportError: Error?
        do {
            applicationSupportURL =
                try builders.discoverApplicationSupport()
            applicationSupportError = nil
        } catch {
            applicationSupportURL = nil
            applicationSupportError = error
        }

        let settingsBootstrapOutcome: SettingsRuntimeBootstrapOutcome
        if let applicationSupportURL {
            settingsBootstrapOutcome = builders.bootstrapSettings(
                applicationSupportURL
            )
        } else {
            let code = Int32(
                exactly: (applicationSupportError as NSError?)?.code ?? Int(EIO)
            ) ?? EIO
            settingsBootstrapOutcome = SettingsRuntimeBootstrapOutcome(
                result: .recoveryRequired(
                    .container(
                        .systemCall(
                            operation: "locate Application Support",
                            code: code
                        )
                    )
                ),
                trustedContainer: nil
            )
        }

        let containerBootstrapFailure:
            SettingsRuntimeContainerFailure? =
            if case .recoveryRequired(
                .container(let failure)
            ) = settingsBootstrapOutcome.result {
                failure
            } else {
                nil
            }
        let sharedServices = builders.makeSharedServices(
            settingsBootstrapOutcome.trustedContainer,
            applicationSupportError,
            containerBootstrapFailure
        )
        let settings = AppSettings(
            production: settingsBootstrapOutcome.result
        )
        let libraryChanges = LibraryChangeBroadcaster()
        self.settings = settings
        self.libraryChanges = libraryChanges
        libraryStoreFactory = builders.makeLibraryStoreFactory(
            sharedServices,
            settings,
            libraryChanges
        )
    }

    func makeLibraryStore(sceneID: UUID = UUID()) -> LibraryStore {
        libraryStoreFactory.makeStore(sceneID: sceneID)
    }
}

/// StateObject retains one holder per scene; unused view values never load a library.
@MainActor
final class ParallaxSceneStore: ObservableObject {
    private let makeStore: @MainActor () -> LibraryStore
    private var cachedStore: LibraryStore?
    let mainWindows: ParallaxMainWindowRegistry
    private(set) weak var window: NSWindow?

    var store: LibraryStore {
        if let cachedStore { return cachedStore }
        let store = makeStore()
        cachedStore = store
        return store
    }

    convenience init(factory: ParallaxLibraryStoreFactory) {
        self.init(mainWindows: factory.sharedServices.mainWindows) {
            factory.makeStore()
        }
    }

    init(
        mainWindows: ParallaxMainWindowRegistry,
        makeStore: @escaping @MainActor () -> LibraryStore
    ) {
        self.mainWindows = mainWindows
        self.makeStore = makeStore
    }

    func captureWindow(_ window: NSWindow) {
        self.window = window
        mainWindows.register(window, store: store)
    }

    @discardableResult
    func windowWillClose(_ closingWindow: NSWindow) -> Task<Void, Never>? {
        guard window === closingWindow else { return nil }
        mainWindows.remove(closingWindow)
        window = nil
        let store = store
        store.endProfileEditing()
        return Task { await store.closeProfileEditing() }
    }
}

@MainActor
final class ParallaxMainWindowRegistry {
    private final class WeakWindow {
        weak var value: NSWindow?
        weak var store: LibraryStore?
        init(_ value: NSWindow, store: LibraryStore?) { self.value = value; self.store = store }
    }

    private var windows: [WeakWindow] = []
    private var pendingOpen: (applicationID: UUID, profileID: UUID)?

    func register(_ window: NSWindow, store: LibraryStore? = nil) {
        windows.removeAll { $0.value == nil || $0.value === window }
        windows.append(WeakWindow(window, store: store))
        if let pendingOpen, let store {
            self.pendingOpen = nil
            open(pendingOpen, in: store)
        }
    }

    func remove(_ window: NSWindow) {
        windows.removeAll { $0.value == nil || $0.value === window }
    }

    var availableWindow: NSWindow? {
        windows.compactMap(\.value).first {
            $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
    }

    /// Menu-bar opens belong to a main scene so every required review has a
    /// visible presenter. If no scene exists, consume the request on capture.
    func requestOpen(applicationID: UUID, profileID: UUID) {
        let request = (applicationID: applicationID, profileID: profileID)
        if let window = availableWindow, let store = windows.first(where: { $0.value === window })?.store {
            open(request, in: store)
        } else { pendingOpen = request }
    }

    private func open(_ request: (applicationID: UUID, profileID: UUID), in store: LibraryStore) {
        store.reloadFromSharedRepository()
        guard let application = store.applications.first(where: { $0.id == request.applicationID }),
              let profile = application.profiles.first(where: { $0.id == request.profileID }) else {
            store.errorMessage = SpaceLinkError.unknownSpace.localizedDescription
            return
        }
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id
        store.sceneCoordinator.requestedApplicationPage = application.id
        if let running = store.runningApplicationInstances(for: application).first(where: { $0.profileID == profile.id && $0.isActionable }) {
            _ = store.requestActivate(running, from: application)
        } else { store.launch(profile, application: application) }
    }
}

@MainActor
final class ParallaxTerminationCoordinator {
    private let waitForDeadline: @MainActor () async throws -> Void
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var reply: (@MainActor (Bool) -> Void)?

    init(
        waitForDeadline: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .seconds(3))
        }
    ) {
        self.waitForDeadline = waitForDeadline
    }

    func requestTermination(
        registry: ProfileEditorDraftRegistry,
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard self.reply == nil else { return .terminateLater }
        guard registry.hasPendingCleanup else { return .terminateNow }
        self.reply = reply
        cleanupTask = Task {
            await registry.discardAllDrafts()
            finish()
        }
        deadlineTask = Task {
            do {
                try await waitForDeadline()
                finish()
            } catch {
                // Cleanup finished before the deadline.
            }
        }
        return .terminateLater
    }

    private func finish() {
        guard let reply else { return }
        self.reply = nil
        cleanupTask?.cancel()
        deadlineTask?.cancel()
        cleanupTask = nil
        deadlineTask = nil
        reply(true)
    }
}
