import XCTest
@testable import Parallax

final class LibraryStoreStartupRecoveryTests: XCTestCase {
    @MainActor
    func testSharedActivityBootstrapFailureFailsClosed()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Startup-Infrastructure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: support) }
        let persistence = LibraryPersistence(
            applicationSupportURL: support
        )
        try persistence.save([
            ManagedApplication(
                displayName: "Healthy",
                appPath: "/Applications/Healthy.app"
            )
        ])
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        let store = LibraryStore(
            persistence: persistence,
            repository: repository,
            profileActivityRegistry: ProfileActivityRegistry(),
            profileActivityBootstrapError:
                StartupInfrastructureFailure.activityJournal,
            settings: AppSettings(
                userDefaults: try XCTUnwrap(
                    UserDefaults(
                        suiteName:
                            "parallax.startup-bootstrap.\(UUID().uuidString)"
                    )
                )
            )
        )

        guard case .recoveryRequired(_, let message) =
            store.loadState
        else {
            return XCTFail(
                "Durable activity bootstrap failure must fail closed."
            )
        }
        XCTAssertTrue(message.contains("activity journal"))
        XCTAssertEqual(store.infrastructureFailureMessage, message)
        XCTAssertEqual(store.errorMessage, message)
        XCTAssertTrue(store.applications.isEmpty)

        store.reloadFromSharedRepository()

        guard case .recoveryRequired(_, let reloadedMessage) =
            store.loadState
        else {
            return XCTFail(
                "A shared repository reload must preserve infrastructure recovery."
            )
        }
        XCTAssertEqual(reloadedMessage, message)
        XCTAssertEqual(store.errorMessage, message)
        XCTAssertTrue(store.applications.isEmpty)

        store.load()

        guard case .recoveryRequired(_, let loadedMessage) =
            store.loadState
        else {
            return XCTFail(
                "A direct load must preserve infrastructure recovery."
            )
        }
        XCTAssertEqual(loadedMessage, message)
        XCTAssertEqual(store.errorMessage, message)
        XCTAssertTrue(store.applications.isEmpty)
    }

    @MainActor
    func testMigrationBlockerStopsStartupReloadInsteadOfRecursing()
        throws
    {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        _ = try workspace.installFixture(
            named: "slash-containing-storage-name.json"
        )

        let suiteName =
            "parallax.startup-recovery.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            userDefaults.removePersistentDomain(
                forName: suiteName
            )
        }
        let settings = AppSettings(userDefaults: userDefaults)
        let persistence = LibraryPersistence(
            applicationSupportURL:
                workspace.applicationSupportURL
        )
        let repository = LibraryRepository(
            applicationSupportURL:
                workspace.applicationSupportURL
        )

        let store = LibraryStore(
            persistence: persistence,
            repository: repository,
            settings: settings
        )

        guard case .recoveryRequired = store.loadState else {
            return XCTFail(
                "A migration blocker should produce a recoverable startup state."
            )
        }
        XCTAssertNotNil(store.migrationRequiredLibrary)
        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }
}

extension LibraryStoreStartupRecoveryTests {
    @MainActor
    func testInfrastructureFailureBlocksDestructiveLibraryRecovery()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Startup-Destructive-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: support) }
        let persistence = LibraryPersistence(
            applicationSupportURL: support
        )
        try persistence.save([
            ManagedApplication(
                displayName: "Healthy",
                appPath: "/Applications/Healthy.app"
            )
        ])
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        let store = LibraryStore(
            persistence: persistence,
            repository: repository,
            profileActivityRegistry: ProfileActivityRegistry(),
            profileActivityBootstrapError:
                StartupInfrastructureFailure.activityJournal,
            settings: AppSettings(
                userDefaults: try XCTUnwrap(
                    UserDefaults(
                        suiteName:
                            "parallax.startup-destructive.\(UUID().uuidString)"
                    )
                )
            )
        )
        XCTAssertNotNil(store.infrastructureFailureMessage)

        let primaryURL = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        let originalBytes = try Data(contentsOf: primaryURL)

        // The destructive affordance must not even be offered.
        XCTAssertNil(store.startOverAuthorization())

        // Quarantine runs before the reload, so a bare authorization must be
        // refused before it can set a healthy library aside.
        let authorization = LibraryStore.StartOverAuthorization(
            failedPrimarySHA256: LibraryPersistence.sha256(originalBytes)
        )
        XCTAssertFalse(store.confirmStartOver(authorization))
        XCTAssertEqual(try Data(contentsOf: primaryURL), originalBytes)
        XCTAssertEqual(
            store.errorMessage,
            String(
                localized:
                    "Parallax cannot start over while a startup problem is blocking it. Quit and reopen Parallax, then try again."
            )
        )

        XCTAssertFalse(store.restoreLatestVerifiedBackup())
        XCTAssertEqual(try Data(contentsOf: primaryURL), originalBytes)
        XCTAssertEqual(
            store.errorMessage,
            String(
                localized:
                    "Parallax cannot restore a backup while a startup problem is blocking it. Quit and reopen Parallax, then try again."
            )
        )

        // The gate itself must still be holding after both refusals.
        guard case .recoveryRequired = store.loadState else {
            return XCTFail(
                "Refusing recovery actions must not leave recovery state."
            )
        }
    }
}

private enum StartupInfrastructureFailure: LocalizedError {
    case activityJournal

    var errorDescription: String? {
        "The activity journal is unavailable."
    }
}
