import Darwin
import Foundation

@MainActor
final class ParallaxSharedServices {
    let profileActivityRegistry: ProfileActivityRegistry
    let launchHistoryStore: LaunchHistoryStore
    let managedAppWorkaroundStore: ManagedAppWorkaroundStore
    let managedAppRecoveryLedger: ManagedAppRecoveryLedger
    let profileActivityInitializationError: Error?

    init(
        trustedContainer: TrustedParallaxContainer?,
        applicationSupportInitializationError: Error?
    ) {
        do {
            guard let trustedContainer else {
                throw applicationSupportInitializationError
                    ?? CocoaError(.fileNoSuchFile)
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
        storeBuilder(
            sharedServices,
            settings,
            libraryChanges,
            sceneID
        )
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
                Error?
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
                makeSharedServices: { trustedContainer, error in
                    ParallaxSharedServices(
                        trustedContainer: trustedContainer,
                        applicationSupportInitializationError: error
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
    let relayStore: RelayAppStore

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
                (applicationSupportError as NSError?)?.code ?? Int(EIO)
            )
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

        let sharedServices = builders.makeSharedServices(
            settingsBootstrapOutcome.trustedContainer,
            applicationSupportError
        )
        let settings = AppSettings(
            production: settingsBootstrapOutcome.result
        )
        let libraryChanges = LibraryChangeBroadcaster()
        self.settings = settings
        self.libraryChanges = libraryChanges
        relayStore = RelayAppStore.production(
            trustedContainerURL:
                settingsBootstrapOutcome.trustedContainer?.url
        )
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
