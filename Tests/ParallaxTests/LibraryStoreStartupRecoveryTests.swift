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

private enum StartupInfrastructureFailure: LocalizedError {
    case activityJournal

    var errorDescription: String? {
        "The activity journal is unavailable."
    }
}
