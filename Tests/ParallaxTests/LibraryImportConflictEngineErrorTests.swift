import Foundation
import XCTest
@testable import Parallax

final class LibraryImportConflictEngineErrorTests: XCTestCase {
    func testApplicationResolutionRejectsProfileScopedTarget() throws {
        let (existing, imported, conflict) = try applicationConflict()

        assertResolutionError(
            .conflictResolutionDoesNotMatch,
            existing: existing,
            imported: imported,
            conflict: conflict,
            resolution: .keepExisting(
                applicationID: existing.application.id,
                profileID: UUID()
            )
        )
    }

    func testApplicationResolutionRejectsUnmatchedTarget() throws {
        let (existing, imported, conflict) = try applicationConflict()

        assertResolutionError(
            .conflictResolutionDoesNotMatch,
            existing: existing,
            imported: imported,
            conflict: conflict,
            resolution: .useImported(applicationID: UUID())
        )
    }

    func testKeepBothRejectsWrongConflictScope() throws {
        let (existing, imported, conflict) = try applicationConflict()

        assertResolutionError(
            .wrongKeepBothScope,
            existing: existing,
            imported: imported,
            conflict: conflict,
            resolution: .keepBoth(
                .profile(
                    renamedTo: "Imported",
                    identity: LibraryImportFreshProfileIdentity(
                        id: UUID(),
                        storageID: UUID()
                    )
                )
            )
        )
    }

    func testKeepBothApplicationRejectsIncompleteNestedIdentityMap() throws {
        let importedProfile = profile(name: "Work")
        let (existing, imported, conflict) = try applicationConflict(
            profiles: [importedProfile]
        )

        assertResolutionError(
            .freshIdentityCollision,
            existing: existing,
            imported: imported,
            conflict: conflict,
            resolution: .keepBoth(
                .application(
                    renamedTo: "Imported",
                    identity: LibraryImportFreshApplicationIdentity(
                        id: UUID(),
                        storageID: UUID(),
                        profileIdentities: [:]
                    )
                )
            )
        )
    }

    func testKeepBothApplicationRejectsCollidingIdentity() throws {
        let (existing, imported, conflict) = try applicationConflict()

        assertResolutionError(
            .freshIdentityCollision,
            existing: existing,
            imported: imported,
            conflict: conflict,
            resolution: .keepBoth(
                .application(
                    renamedTo: "Imported",
                    identity: LibraryImportFreshApplicationIdentity(
                        id: existing.application.id,
                        storageID: UUID(),
                        profileIdentities: [:]
                    )
                )
            )
        )
    }

    func testKeepBothRejectsEmptyAndCollidingRename() throws {
        let (existing, imported, conflict) = try applicationConflict()
        let identity = LibraryImportFreshApplicationIdentity(
            id: UUID(),
            storageID: UUID(),
            profileIdentities: [:]
        )

        for (rename, expectedError) in [
            ("   ", LibraryImportConflictEngineError.emptyRename),
            ("BROWSER", LibraryImportConflictEngineError.renameCollision),
        ] {
            assertResolutionError(
                expectedError,
                existing: existing,
                imported: imported,
                conflict: conflict,
                resolution: .keepBoth(
                    .application(renamedTo: rename, identity: identity)
                )
            )
        }
    }

    func testApplicationMatchingReportsAmbiguousExactIdentitySignals() throws {
        let first = application(
            name: "First",
            path: "/Applications/First.app"
        )
        let second = application(
            name: "Second",
            path: "/Applications/Second.app"
        )
        let imported = application(
            id: first.application.id,
            storageID: second.application.storageID,
            name: "Imported",
            path: "/Applications/Imported.app"
        )

        let preview = try LibraryImportConflictEngine.resolve(
            existing: [first, second],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(preview.conflicts.first)

        XCTAssertNil(preview.applications)
        XCTAssertEqual(conflict.scope, .application)
        XCTAssertTrue(conflict.reasons.contains(.applicationIdentity))
        XCTAssertTrue(
            conflict.reasons.contains(.applicationStorageIdentity)
        )
        XCTAssertTrue(
            conflict.reasons.contains(.ambiguousApplicationMatch)
        )
        XCTAssertEqual(
            Set(conflict.existingApplicationIDs),
            [first.application.id, second.application.id]
        )
    }

    func testProfileMatchingReportsAmbiguousExactIdentitySignals() throws {
        let firstProfile = profile(name: "One", arguments: "--one")
        let secondProfile = profile(name: "Two", arguments: "--two")
        let appID = UUID()
        let appStorageID = UUID()
        let existing = application(
            id: appID,
            storageID: appStorageID,
            name: "Browser",
            path: "/Applications/Browser.app",
            profiles: [firstProfile, secondProfile]
        )
        let importedProfile = LaunchProfile(
            id: firstProfile.id,
            storageID: secondProfile.storageID,
            name: "Imported",
            argumentsText: "--imported"
        )
        let imported = application(
            id: appID,
            storageID: appStorageID,
            name: "Browser",
            path: "/Applications/Browser.app",
            profiles: [importedProfile]
        )

        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(
            preview.conflicts.first { $0.scope == .profile }
        )

        XCTAssertNil(preview.applications)
        XCTAssertTrue(conflict.reasons.contains(.profileIdentity))
        XCTAssertTrue(conflict.reasons.contains(.profileStorageIdentity))
        XCTAssertTrue(conflict.reasons.contains(.ambiguousProfileMatch))
        XCTAssertEqual(
            Set(conflict.existingProfileIDs),
            [firstProfile.id, secondProfile.id]
        )
    }

    private func applicationConflict(
        profiles: [LaunchProfile] = []
    ) throws -> (
        LibraryImportApplication,
        LibraryImportApplication,
        LibraryImportConflict
    ) {
        let existing = application(
            name: "Browser",
            path: "/Applications/Browser.app"
        )
        let imported = application(
            name: "browser",
            path: "/Applications/Other.app",
            profiles: profiles
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        return (existing, imported, try XCTUnwrap(preview.conflicts.first))
    }

    private func assertResolutionError(
        _ expected: LibraryImportConflictEngineError,
        existing: LibraryImportApplication,
        imported: LibraryImportApplication,
        conflict: LibraryImportConflict,
        resolution: LibraryImportConflictResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LibraryImportConflictEngine.resolve(
                existing: [existing],
                imported: [imported],
                resolutions: [conflict.id: resolution]
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LibraryImportConflictEngineError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func application(
        id: UUID = UUID(),
        storageID: UUID = UUID(),
        name: String,
        path: String,
        profiles: [LaunchProfile] = []
    ) -> LibraryImportApplication {
        LibraryImportApplication(
            application: ManagedApplication(
                id: id,
                storageID: storageID,
                displayName: name,
                appPath: path,
                profiles: profiles
            ),
            canonicalApplicationPath: path
        )
    }

    private func profile(
        name: String,
        arguments: String = ""
    ) -> LaunchProfile {
        LaunchProfile(name: name, argumentsText: arguments)
    }
}
