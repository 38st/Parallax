import XCTest
@testable import Parallax

final class ParallaxAppCompositionTests: XCTestCase {
    private enum Event: Equatable {
        case discovery
        case settingsBootstrap
        case sharedServices
        case storeFactory
    }

    @MainActor
    func testTypedCompositionOrdersBootstrapAndSharesOneFacade() throws {
        let support = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "parallax-app-composition-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: support.path
        )
        defer { try? FileManager.default.removeItem(at: support) }

        var events: [Event] = []
        var bootstrappedContainer: TrustedParallaxContainer?
        var capturedServices: ParallaxSharedServices?
        let emptyLegacy = SettingsLegacySnapshotClassifier.classify([:])
        let composition = ParallaxAppComposition(
            builders: .init(
                discoverApplicationSupport: {
                    events.append(.discovery)
                    return support
                },
                bootstrapSettings: { discoveredSupport in
                    events.append(.settingsBootstrap)
                    let outcome = SettingsRuntimeBootstrapper(
                        applicationSupportURL: discoveredSupport,
                        legacyApplicationIdentifier:
                            "test.app.composition",
                        legacyCaptureOverride: { emptyLegacy }
                    ).bootstrapOutcome()
                    bootstrappedContainer = outcome.trustedContainer
                    return outcome
                },
                makeSharedServices: {
                    trustedContainer,
                    error,
                    containerBootstrapFailure in
                    events.append(.sharedServices)
                    XCTAssertNil(error)
                    XCTAssertNil(containerBootstrapFailure)
                    XCTAssertTrue(
                        trustedContainer === bootstrappedContainer
                    )
                    let services = ParallaxSharedServices(
                        trustedContainer: trustedContainer,
                        applicationSupportInitializationError: error,
                        containerBootstrapFailure:
                            containerBootstrapFailure
                    )
                    capturedServices = services
                    return services
                },
                makeLibraryStoreFactory: {
                    services,
                    settings,
                    libraryChanges in
                    events.append(.storeFactory)
                    XCTAssertTrue(services === capturedServices)
                    XCTAssertEqual(
                        settings.persistenceAuthority,
                        .versionedRepository
                    )
                    return ParallaxLibraryStoreFactory(
                        sharedServices: services,
                        settings: settings,
                        libraryChanges: libraryChanges,
                        storeBuilder: {
                            services,
                            settings,
                            libraryChanges,
                            sceneID in
                            LibraryStore(
                                persistence:
                                    CompositionLibraryPersistence(),
                                profileActivityRegistry:
                                    services.profileActivityRegistry,
                                profileActivityBootstrapError:
                                    services
                                    .profileActivityInitializationError,
                                launchHistoryStore:
                                    services.launchHistoryStore,
                                managedAppWorkaroundStore:
                                    services.managedAppWorkaroundStore,
                                managedAppRecoveryLedger:
                                    services.managedAppRecoveryLedger,
                                settings: settings,
                                sceneID: sceneID,
                                libraryChangeBroadcaster: libraryChanges
                            )
                        }
                    )
                }
            )
        )

        XCTAssertEqual(
            events,
            [
                .discovery,
                .settingsBootstrap,
                .sharedServices,
                .storeFactory,
            ]
        )
        XCTAssertNotNil(bootstrappedContainer)
        XCTAssertTrue(
            composition.settings
                === composition.libraryStoreFactory.settings
        )
        XCTAssertTrue(
            composition.libraryChanges
                === composition.libraryStoreFactory.libraryChanges
        )
        XCTAssertTrue(
            composition.libraryStoreFactory.sharedServices
                === capturedServices
        )
        XCTAssertTrue(
            composition.libraryStoreFactory.sharedServices
                .corporateUsageStore
                === capturedServices?.corporateUsageStore
        )
        XCTAssertTrue(
            composition.libraryStoreFactory.sharedServices
                .corporateAccountOperationCoordinator
                === capturedServices?
                    .corporateAccountOperationCoordinator
        )

        let menuSceneID = UUID()
        let windowSceneID = UUID()
        let menuStore = composition.makeLibraryStore(
            sceneID: menuSceneID
        )
        let windowStore = composition.libraryStoreFactory.makeStore(
            sceneID: windowSceneID
        )

        XCTAssertFalse(menuStore === windowStore)
        XCTAssertEqual(menuStore.sceneID, menuSceneID)
        XCTAssertEqual(windowStore.sceneID, windowSceneID)
        XCTAssertTrue(menuStore.settings === composition.settings)
        XCTAssertTrue(windowStore.settings === composition.settings)
        XCTAssertTrue(
            menuStore.libraryChangeBroadcaster
                === composition.libraryChanges
        )
        XCTAssertTrue(
            windowStore.libraryChangeBroadcaster
                === composition.libraryChanges
        )
        XCTAssertTrue(
            menuStore.profileActivityRegistry
                === windowStore.profileActivityRegistry
        )
    }

    @MainActor
    func testDiscoveryFailureSkipsBootstrapAndFailsClosed() {
        var didBootstrap = false
        var receivedInitializationError: Error?
        let composition = ParallaxAppComposition(
            builders: .init(
                discoverApplicationSupport: {
                    throw CompositionTestError.discoveryFailed
                },
                bootstrapSettings: { _ in
                    didBootstrap = true
                    preconditionFailure(
                        "Settings bootstrap must not run without a root."
                    )
                },
                makeSharedServices: {
                    trustedContainer,
                    error,
                    containerBootstrapFailure in
                    XCTAssertNil(trustedContainer)
                    XCTAssertNotNil(containerBootstrapFailure)
                    receivedInitializationError = error
                    return ParallaxSharedServices(
                        trustedContainer: trustedContainer,
                        applicationSupportInitializationError: error,
                        containerBootstrapFailure:
                            containerBootstrapFailure
                    )
                },
                makeLibraryStoreFactory: {
                    ParallaxLibraryStoreFactory(
                        sharedServices: $0,
                        settings: $1,
                        libraryChanges: $2
                    )
                }
            )
        )

        XCTAssertFalse(didBootstrap)
        XCTAssertNotNil(receivedInitializationError)
        XCTAssertEqual(
            composition.settings.persistenceAuthority,
            .recoveryOnly
        )
        XCTAssertFalse(composition.settings.canProvideVerifiedSettings)
        XCTAssertEqual(
            composition.libraryStoreFactory.sharedServices
                .profileActivityInitializationError
                as? CompositionTestError,
            .discoveryFailed
        )
    }

    @MainActor
    func testContainerBootstrapFailureReachesSharedServices() throws {
        let failure = SettingsRuntimeContainerFailure
            .unsafeExistingItem(path: "/private/tmp/Parallax")
        var receivedFailure: SettingsRuntimeContainerFailure?

        let composition = ParallaxAppComposition(
            builders: .init(
                discoverApplicationSupport: {
                    URL(
                        fileURLWithPath: "/private/tmp",
                        isDirectory: true
                    )
                },
                bootstrapSettings: { _ in
                    SettingsRuntimeBootstrapOutcome(
                        result: .recoveryRequired(
                            .container(failure)
                        ),
                        trustedContainer: nil
                    )
                },
                makeSharedServices: {
                    trustedContainer,
                    applicationSupportError,
                    containerBootstrapFailure in
                    XCTAssertNil(trustedContainer)
                    XCTAssertNil(applicationSupportError)
                    receivedFailure = containerBootstrapFailure
                    return ParallaxSharedServices(
                        trustedContainer: trustedContainer,
                        applicationSupportInitializationError:
                            applicationSupportError,
                        containerBootstrapFailure:
                            containerBootstrapFailure
                    )
                },
                makeLibraryStoreFactory: {
                    ParallaxLibraryStoreFactory(
                        sharedServices: $0,
                        settings: $1,
                        libraryChanges: $2
                    )
                }
            )
        )

        XCTAssertEqual(receivedFailure, failure)
        let propagated = try XCTUnwrap(
            composition.libraryStoreFactory.sharedServices
                .profileActivityInitializationError
                as? SettingsRuntimeContainerFailure
        )
        XCTAssertEqual(propagated, failure)
        XCTAssertTrue(
            propagated.localizedDescription.contains(
                "/private/tmp/Parallax"
            )
        )
    }
}

private enum CompositionTestError: Error, Equatable {
    case discoveryFailed
}

private struct CompositionLibraryPersistence: LibraryPersisting {
    func load() throws -> [ManagedApplication] { [] }

    func save(_ applications: [ManagedApplication]) throws {}
}
