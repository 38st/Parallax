import Foundation
import XCTest
@testable import Parallax

final class DestructiveActionRequestTests: XCTestCase {
    func testPresentationAndAuthorityRemainBoundWhenSelectionAndDraftChange() throws {
        let fixture = makeFixture()
        var selectedApplicationID = fixture.request.applicationID
        var selectedProfileID = fixture.request.profileID
        var draftName = "Work"
        let presentation = fixture.request.confirmationPresentation

        selectedApplicationID = UUID()
        selectedProfileID = UUID()
        draftName = "Retargeted draft"

        XCTAssertNotEqual(selectedApplicationID, fixture.request.applicationID)
        XCTAssertNotEqual(selectedProfileID, fixture.request.profileID)
        XCTAssertNotEqual(draftName, presentation.profileName)
        XCTAssertEqual(presentation.requestID, fixture.request.requestID)
        XCTAssertEqual(presentation.sceneID, fixture.request.sceneID)
        XCTAssertEqual(presentation.applicationName, "Chromium")
        XCTAssertEqual(presentation.profileName, "Work")
        XCTAssertEqual(
            presentation.canonicalPath,
            "/Volumes/Profiles/.parallax/Applications/app/Profiles/work"
        )
        XCTAssertTrue(presentation.message.contains("Chromium"))
        XCTAssertTrue(presentation.message.contains("Work"))
        XCTAssertTrue(presentation.message.contains(presentation.canonicalPath))

        let authorization = try fixture.request.authorizeExecution(
            currentTarget: fixture.current,
            activity: fixture.inactive
        )
        XCTAssertEqual(authorization.requestID, fixture.request.requestID)
        XCTAssertFalse(authorization.usedExpertOverride)
    }

    func testDifferentLogicalOrStorageTargetCannotBeRetargeted() throws {
        let fixture = makeFixture()
        let retargeted = fixture.current.replacing(
            profileID: UUID(),
            profileStorageID: UUID()
        )

        assertRejected(
            fixture.request,
            current: retargeted,
            activity: fixture.inactive,
            code: .targetRetargeted
        )
    }

    func testRemovedTargetIsRejected() throws {
        let fixture = makeFixture()

        assertRejected(
            fixture.request,
            current: nil,
            activity: fixture.inactive,
            code: .targetRemoved
        )
    }

    func testCanonicalPathAndFileIdentityChangesAreRejected() throws {
        let fixture = makeFixture()
        let moved = fixture.current.replacing(
            path: DestructiveActionPathSnapshot(
                canonicalURL: URL(
                    fileURLWithPath: "/Volumes/Other/Profile",
                    isDirectory: true
                ),
                fileIdentity: fixture.current.path.fileIdentity
            )
        )
        assertRejected(
            fixture.request,
            current: moved,
            activity: fixture.inactive,
            code: .canonicalPathChanged
        )

        let replaced = fixture.current.replacing(
            path: DestructiveActionPathSnapshot(
                canonicalURL: fixture.current.path.canonicalURL,
                fileIdentity: FileSystemObjectIdentity(
                    volumeID: 90,
                    fileID: 91
                )
            )
        )
        assertRejected(
            fixture.request,
            current: replaced,
            activity: fixture.inactive,
            code: .fileIdentityChanged
        )
    }

    func testConfigurationAndLibraryVersionChangesAreRejected() throws {
        let fixture = makeFixture()
        assertRejected(
            fixture.request,
            current: fixture.current.replacing(configurationRevision: 43),
            activity: fixture.inactive,
            code: .configurationChanged
        )
        assertRejected(
            fixture.request,
            current: fixture.current.replacing(
                libraryVersion: LibraryVersionToken(
                    revision: LibraryRevision(rawValue: 8),
                    primarySHA256: "new"
                )
            ),
            activity: fixture.inactive,
            code: .staleLibraryVersion
        )
    }

    func testActiveTargetBlocksWithoutExactExpertRiskAuthorization() throws {
        let fixture = makeFixture()
        let active = DestructiveActionActivitySnapshot(
            identity: fixture.request.activityIdentity,
            state: .active
        )
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: active,
            code: .activeProfileData
        )

        let wrongRequest = makeFixture(requestID: UUID()).request
        let wrongOverride = wrongRequest.makeExpertOverrideAuthorization(
            acknowledging: .profileDataCorruptionAndProcessInstability
        )
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: active,
            override: wrongOverride,
            code: .invalidExpertOverride
        )

        let override = fixture.request.makeExpertOverrideAuthorization(
            acknowledging: .profileDataCorruptionAndProcessInstability
        )
        XCTAssertTrue(
            override.acknowledgedRisk.warningMessage
                .localizedCaseInsensitiveContains("corrupt")
        )
        XCTAssertTrue(
            override.acknowledgedRisk.warningMessage
                .localizedCaseInsensitiveContains("unstable")
        )
        let authorized = try fixture.request.authorizeExecution(
            currentTarget: fixture.current,
            activity: active,
            expertOverride: override
        )
        XCTAssertTrue(authorized.usedExpertOverride)
        XCTAssertEqual(authorized.requestID, fixture.request.requestID)
        XCTAssertEqual(
            authorized.expertOverrideAuthorizationID,
            override.authorizationID
        )
        XCTAssertEqual(
            authorized.acknowledgedRisk,
            .profileDataCorruptionAndProcessInstability
        )
    }

    func testActivityCheckForAnotherStorageTargetIsRejected() throws {
        let fixture = makeFixture()
        let mismatched = DestructiveActionActivitySnapshot(
            identity: ProfileActivityIdentity(
                applicationID: fixture.request.applicationID,
                applicationStorageID: fixture.request.applicationStorageID,
                profileID: fixture.request.profileID,
                profileStorageID: UUID()
            ),
            state: .inactive
        )

        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: mismatched,
            code: .activitySnapshotMismatch
        )
    }

    func testAmbiguousActivityFailsClosedButAllowsSameExplicitOverride() throws {
        let fixture = makeFixture()
        let ambiguous = DestructiveActionActivitySnapshot(
            identity: fixture.request.activityIdentity,
            state: .ambiguous
        )
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: ambiguous,
            code: .activeProfileData
        )

        let override = fixture.request.makeExpertOverrideAuthorization(
            acknowledging: .profileDataCorruptionAndProcessInstability
        )
        XCTAssertNoThrow(
            try fixture.request.authorizeExecution(
                currentTarget: fixture.current,
                activity: ambiguous,
                expertOverride: override
            )
        )
    }

    private func makeFixture(
        requestID: UUID = UUID()
    ) -> DestructiveActionFixture {
        let applicationID = UUID()
        let applicationStorageID = UUID()
        let profileID = UUID()
        let profileStorageID = UUID()
        let path = DestructiveActionPathSnapshot(
            canonicalURL: URL(
                fileURLWithPath:
                    "/Volumes/Profiles/.parallax/Applications/app/Profiles/work",
                isDirectory: true
            ),
            fileIdentity: FileSystemObjectIdentity(
                volumeID: 10,
                fileID: 11
            )
        )
        let version = LibraryVersionToken(
            revision: LibraryRevision(rawValue: 7),
            primarySHA256: "prior"
        )
        let request = DestructiveActionRequest(
            requestID: requestID,
            sceneID: UUID(),
            operation: .clearProfileData,
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileID: profileID,
            profileStorageID: profileStorageID,
            applicationName: "Chromium",
            profileName: "Work",
            path: path,
            configurationRevision: 42,
            libraryVersion: version
        )
        let current = DestructiveActionCurrentTarget(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileID: profileID,
            profileStorageID: profileStorageID,
            path: path,
            configurationRevision: 42,
            libraryVersion: version
        )
        return DestructiveActionFixture(
            request: request,
            current: current,
            inactive: DestructiveActionActivitySnapshot(
                identity: request.activityIdentity,
                state: .inactive
            )
        )
    }

    private func assertRejected(
        _ request: DestructiveActionRequest,
        current: DestructiveActionCurrentTarget?,
        activity: DestructiveActionActivitySnapshot,
        override: DestructiveActionExpertOverrideAuthorization? = nil,
        code: DestructiveActionRequestError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try request.authorizeExecution(
                currentTarget: current,
                activity: activity,
                expertOverride: override
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                (error as? DestructiveActionRequestError)?.code,
                code,
                file: file,
                line: line
            )
        }
    }
}

private struct DestructiveActionFixture {
    let request: DestructiveActionRequest
    let current: DestructiveActionCurrentTarget
    let inactive: DestructiveActionActivitySnapshot
}

private extension DestructiveActionCurrentTarget {
    func replacing(
        profileID: UUID? = nil,
        profileStorageID: UUID? = nil,
        path: DestructiveActionPathSnapshot? = nil,
        configurationRevision: UInt64? = nil,
        libraryVersion: LibraryVersionToken? = nil
    ) -> DestructiveActionCurrentTarget {
        DestructiveActionCurrentTarget(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            profileID: profileID ?? self.profileID,
            profileStorageID: profileStorageID ?? self.profileStorageID,
            path: path ?? self.path,
            configurationRevision:
                configurationRevision ?? self.configurationRevision,
            libraryVersion: libraryVersion ?? self.libraryVersion
        )
    }
}
