import XCTest
@testable import Parallax

final class NewSpaceWorkflowTests: XCTestCase {
    @MainActor
    func testGuidedCreationReusesTemplateAndRecommendedSettings()
        throws
    {
        let application = ManagedApplication(
            displayName: "Chrome",
            appPath: "/Applications/Chrome.app",
            preset: .chrome,
            baseStoragePath:
                FileManager.default.temporaryDirectory.path
        )
        let persistence = NewSpacePersistence(
            applications: [application]
        )
        let (settings, suiteName) = try makeSettings()
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: persistence,
            settings: settings
        )
        let work = try XCTUnwrap(
            store.profileTemplates.first {
                $0.name == "Work"
            }
        )

        let created = try XCTUnwrap(
            store.createSpace(
                named: "Client Work",
                templateID: work.id,
                applicationID: application.id
            )
        )

        XCTAssertEqual(created.name, "Client Work")
        XCTAssertNotNil(
            UserDataDirectoryOptionResolver.resolve(
                in: LaunchArgumentParser.parse(
                    created.argumentsText
                ).tokens
            ).resolvedValue
        )
        XCTAssertEqual(
            created.isolationOwnership.userData,
            .generated
        )
        XCTAssertEqual(
            persistence.applications.first?.profiles,
            [created]
        )
    }

    @MainActor
    func testCreationFailureKeepsLibraryUnchanged() throws {
        let application = ManagedApplication(
            displayName: "Custom",
            appPath: "/Applications/Custom.app",
            baseStoragePath:
                FileManager.default.temporaryDirectory.path
        )
        let persistence = NewSpacePersistence(
            applications: [application]
        )
        let (settings, suiteName) = try makeSettings()
        defer {
            UserDefaults(suiteName: suiteName)?
                .removePersistentDomain(forName: suiteName)
        }
        let store = LibraryStore(
            persistence: persistence,
            settings: settings
        )

        XCTAssertNil(
            store.createSpace(
                named: "   ",
                templateID: nil,
                applicationID: application.id
            )
        )
        XCTAssertTrue(
            persistence.applications[0].profiles.isEmpty
        )
        XCTAssertEqual(
            store.errorMessage,
            "Enter a name for this space."
        )
    }

    @MainActor
    private func makeSettings() throws -> (AppSettings, String) {
        let suiteName =
            "parallax.new-space.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(userDefaults: defaults), suiteName)
    }
}

private final class NewSpacePersistence: LibraryPersisting {
    var applications: [ManagedApplication]

    init(applications: [ManagedApplication]) {
        self.applications = applications
    }

    func load() throws -> [ManagedApplication] {
        applications
    }

    func loadResult() throws -> LibraryLoadResult {
        .current(applications)
    }

    func save(_ applications: [ManagedApplication]) throws {
        self.applications = applications
    }
}
