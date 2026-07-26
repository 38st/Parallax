import XCTest
@testable import Parallax

final class LibraryEditSessionTests: XCTestCase {
    @MainActor
    func testConcurrentApplicationSessionsMergeNonOverlappingFields() {
        let original = makeApplication()
        let first = ManagedApplicationEditSession(
            application: original,
            libraryVersion: version(1)
        )
        let second = ManagedApplicationEditSession(
            application: original,
            libraryVersion: version(1)
        )
        first.draft.displayName = "First Window"
        second.draft.preset = .chrome
        var current = original

        let firstResult = first.apply(
            to: current,
            libraryVersion: version(1)
        ) { merged, expectedVersion in
            XCTAssertEqual(expectedVersion, self.version(1))
            current = merged
            return (merged, self.version(2))
        }
        let secondResult = second.apply(
            to: current,
            libraryVersion: version(2)
        ) { merged, expectedVersion in
            XCTAssertEqual(expectedVersion, self.version(2))
            current = merged
            return (merged, self.version(3))
        }

        XCTAssertEqual(firstResult, .applied(version: version(2)))
        XCTAssertEqual(secondResult, .applied(version: version(3)))
        XCTAssertEqual(current.displayName, "First Window")
        XCTAssertEqual(current.preset, .chrome)
        XCTAssertEqual(current.id, original.id)
        XCTAssertEqual(current.storageID, original.storageID)
        XCTAssertEqual(current.profiles, original.profiles)
        XCTAssertEqual(first.origin.libraryRevision, version(1).revision)
        XCTAssertEqual(first.origin.libraryFingerprint, "fingerprint-1")
        XCTAssertEqual(first.baselineVersion, version(2))
    }

    @MainActor
    func testExternalRefreshDoesNotReplaceLocalProfileDraftAndApplyMergesIt() {
        let application = makeApplication()
        let original = application.profiles[0]
        let session = LaunchProfileEditSession(
            applicationID: application.id,
            profile: original,
            libraryVersion: version(4)
        )
        session.draft.argumentsText = #"--label="partially typed""#
        var externallyChanged = original
        externallyChanged.notes = "Changed in another window"
        externallyChanged.lastLaunchedAt = Date(timeIntervalSince1970: 500)

        XCTAssertEqual(
            session.draft.argumentsText,
            #"--label="partially typed""#,
            "External model delivery must not reset a cursor-owning local draft."
        )

        var persisted: LaunchProfile?
        let result = session.apply(
            to: externallyChanged,
            in: application.id,
            libraryVersion: version(5)
        ) { merged, _ in
            persisted = merged
            return (merged, self.version(6))
        }

        XCTAssertEqual(result, .applied(version: version(6)))
        XCTAssertEqual(
            persisted?.argumentsText,
            #"--label="partially typed""#
        )
        XCTAssertEqual(persisted?.notes, "Changed in another window")
        XCTAssertEqual(
            persisted?.lastLaunchedAt,
            Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(persisted?.storageID, original.storageID)
    }

    @MainActor
    func testOverlappingProfileEditsReportConflictWithoutPersisting() {
        let application = makeApplication()
        let original = application.profiles[0]
        let session = LaunchProfileEditSession(
            applicationID: application.id,
            profile: original,
            libraryVersion: version(1)
        )
        session.draft.name = "Local Name"
        var externallyChanged = original
        externallyChanged.name = "Remote Name"
        var persistenceCalls = 0

        let result = session.apply(
            to: externallyChanged,
            in: application.id,
            libraryVersion: version(2)
        ) { _, _ in
            persistenceCalls += 1
            return (externallyChanged, self.version(3))
        }

        XCTAssertEqual(result, .conflicts([.name]))
        XCTAssertEqual(persistenceCalls, 0)
        XCTAssertEqual(session.draft.name, "Local Name")
        XCTAssertEqual(session.dirtyFields, [.name])
    }

    @MainActor
    func testCancelRestoresBaselineWithoutPersistence() {
        let original = makeApplication()
        let session = ManagedApplicationEditSession(
            application: original,
            libraryVersion: version(2)
        )
        session.draft.displayName = "Unsaved"
        session.draft.appPath = "/Applications/Other.app"

        session.cancel()

        XCTAssertEqual(session.draft.displayName, original.displayName)
        XCTAssertEqual(session.draft.appPath, original.appPath)
        XCTAssertTrue(session.dirtyFields.isEmpty)
        XCTAssertNil(session.lastPersistenceFailure)
    }

    @MainActor
    func testPersistenceFailureKeepsDraftForRetry() {
        let original = makeApplication()
        let session = ManagedApplicationEditSession(
            application: original,
            libraryVersion: version(8)
        )
        session.draft.displayName = "Retry Me"

        let failed = session.apply(
            to: original,
            libraryVersion: version(8)
        ) { _, _ in
            throw TestFailure.rejected
        }

        guard case let .persistenceFailed(failure) = failed else {
            return XCTFail("Expected persistence failure.")
        }
        XCTAssertEqual(failure.message, TestFailure.rejected.localizedDescription)
        XCTAssertEqual(session.draft.displayName, "Retry Me")
        XCTAssertEqual(session.dirtyFields, [.displayName])
        XCTAssertEqual(session.lastPersistenceFailure, failure)

        var persisted: ManagedApplication?
        let retried = session.apply(
            to: original,
            libraryVersion: version(8)
        ) { merged, _ in
            persisted = merged
            return (merged, self.version(9))
        }

        XCTAssertEqual(retried, .applied(version: version(9)))
        XCTAssertEqual(persisted?.displayName, "Retry Me")
        XCTAssertTrue(session.dirtyFields.isEmpty)
        XCTAssertNil(session.lastPersistenceFailure)
    }

    @MainActor
    func testChangedStorageIdentityRejectsApply() {
        let original = makeApplication()
        let session = ManagedApplicationEditSession(
            application: original,
            libraryVersion: version(1)
        )
        session.draft.displayName = "Edited"
        let replaced = ManagedApplication(
            id: original.id,
            storageID: UUID(),
            displayName: original.displayName,
            bundleIdentifier: original.bundleIdentifier,
            appPath: original.appPath,
            preset: original.preset,
            baseStoragePath: original.baseStoragePath,
            profiles: original.profiles
        )

        let result = session.apply(
            to: replaced,
            libraryVersion: version(2)
        ) { _, _ in
            XCTFail("Identity replacement must not be persisted.")
            return (replaced, self.version(3))
        }

        XCTAssertEqual(result, .targetChanged)
        XCTAssertEqual(session.origin.storageID, original.storageID)
        XCTAssertEqual(session.draft.displayName, "Edited")
    }

    private func makeApplication() -> ManagedApplication {
        ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            baseStoragePath: "/Managed",
            profiles: [
                LaunchProfile(
                    name: "Personal",
                    argumentsText: "--safe",
                    environmentText: "NAME=value",
                    notes: "Original"
                )
            ]
        )
    }

    private func version(_ value: UInt64) -> LibraryVersionToken {
        LibraryVersionToken(
            revision: LibraryRevision(rawValue: value),
            primarySHA256: "fingerprint-\(value)"
        )
    }
}

private enum TestFailure: LocalizedError {
    case rejected

    var errorDescription: String? {
        "Simulated persistence rejection."
    }
}
