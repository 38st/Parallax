import Foundation
import XCTest
@testable import Parallax

final class ApplicationRemovalRequestTests: XCTestCase {
    func testConfirmationIsDestructiveAndBoundToExactApplicationAndProfiles()
        throws
    {
        let fixture = try makeFixture(choice: .archive)
        let presentation = fixture.request.confirmationPresentation

        XCTAssertTrue(presentation.isDestructive)
        XCTAssertTrue(presentation.requiresPriorBackup)
        XCTAssertEqual(presentation.requestID, fixture.request.requestID)
        XCTAssertEqual(presentation.sceneID, fixture.request.sceneID)
        XCTAssertEqual(presentation.applicationID, fixture.applicationID)
        XCTAssertEqual(
            presentation.applicationStorageID,
            fixture.applicationStorageID
        )
        XCTAssertEqual(presentation.applicationName, "Chromium")
        XCTAssertEqual(presentation.profileCount, 2)
        XCTAssertEqual(presentation.dataChoice, .archive)
        XCTAssertTrue(presentation.message.contains("Chromium"))
        XCTAssertTrue(presentation.message.contains("2"))
        XCTAssertTrue(
            presentation.message.contains("2 profile configurations")
        )
        XCTAssertFalse(presentation.message.contains("(s)"))
        XCTAssertTrue(
            presentation.externalDataCaveat
                .localizedCaseInsensitiveContains("external")
        )
        XCTAssertTrue(
            presentation.externalDataCaveat
                .localizedCaseInsensitiveContains("not")
        )
        XCTAssertEqual(presentation.managedDataPaths.count, 2)
        XCTAssertEqual(presentation.externalDataPaths.count, 1)
    }

    func testEveryDataChoiceHasTruthfulTransactionOrdering() throws {
        for choice in ApplicationRemovalDataChoice.allCases {
            let fixture = try makeFixture(choice: choice)
            let presentation = fixture.request.confirmationPresentation

            XCTAssertTrue(presentation.message.contains("Chromium"))
            XCTAssertEqual(
                fixture.request.requiredTransactionSteps,
                [
                    .verifyPriorBackup,
                    choice.transactionStep,
                    .commitMetadataRemoval,
                ]
            )
            switch choice {
            case .keep:
                XCTAssertTrue(
                    presentation.message
                        .localizedCaseInsensitiveContains("keep")
                )
            case .archive:
                XCTAssertTrue(
                    presentation.message
                        .localizedCaseInsensitiveContains("archive")
                )
            case .delete:
                XCTAssertTrue(
                    presentation.message
                        .localizedCaseInsensitiveContains("permanently")
                )
            }
        }
    }

    func testRemovedRetargetedStaleAndChangedTargetsAreRejected() throws {
        let fixture = try makeFixture()
        let undo = try fixture.request.acceptPriorBackup(fixture.backup)

        assertRejected(
            fixture.request,
            current: nil,
            activity: fixture.inactiveActivity,
            undo: undo,
            code: .targetRemoved
        )
        assertRejected(
            fixture.request,
            current: fixture.current.replacing(
                applicationStorageID: UUID()
            ),
            activity: fixture.inactiveActivity,
            undo: undo,
            code: .targetRetargeted
        )
        assertRejected(
            fixture.request,
            current: fixture.current.replacing(
                repositoryVersion: LibraryVersionToken(
                    revision: LibraryRevision(rawValue: 9),
                    primarySHA256: "new"
                )
            ),
            activity: fixture.inactiveActivity,
            undo: undo,
            code: .staleRepositoryVersion
        )
        var changedProfiles = fixture.current.profiles
        changedProfiles.removeLast()
        assertRejected(
            fixture.request,
            current: fixture.current.replacing(profiles: changedProfiles),
            activity: fixture.inactiveActivity,
            undo: undo,
            code: .profileTargetsChanged
        )
    }

    func testActivitySnapshotMustCoverEveryExactStorageTargetAndFailsClosed()
        throws
    {
        let fixture = try makeFixture()
        let undo = try fixture.request.acceptPriorBackup(fixture.backup)
        let incomplete = ApplicationRemovalActivitySnapshot(
            profiles: Array(fixture.inactiveActivity.profiles.dropLast())
        )
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: incomplete,
            undo: undo,
            code: .activitySnapshotMismatch
        )

        let active = fixture.activity(state: .active)
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: active,
            undo: undo,
            code: .activeProfileData
        )

        let ambiguous = fixture.activity(state: .ambiguous)
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: ambiguous,
            undo: undo,
            code: .activeProfileData
        )
    }

    func testExpertOverrideAuthorizesOnlyTheExactRemovalRequest() throws {
        let fixture = try makeFixture(choice: .delete)
        let undo = try fixture.request.acceptPriorBackup(fixture.backup)
        let active = fixture.activity(state: .active)
        let other = try makeFixture(choice: .delete)
        let wrongOverride = other.request.makeExpertOverrideAuthorization(
            acknowledging:
                .allManagedProfileDataMayBeCorruptedAndProcessesDestabilized
        )
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: active,
            undo: undo,
            expertOverride: wrongOverride,
            code: .invalidExpertOverride
        )

        let exactOverride =
            fixture.request.makeExpertOverrideAuthorization(
                acknowledging:
                    .allManagedProfileDataMayBeCorruptedAndProcessesDestabilized
            )
        let authorization = try fixture.request.authorizeExecution(
            currentTarget: fixture.current,
            activity: active,
            priorBackup: undo,
            expertOverride: exactOverride
        )

        XCTAssertTrue(authorization.usedExpertOverride)
        XCTAssertEqual(
            authorization.expertOverrideAuthorizationID,
            exactOverride.authorizationID
        )
        XCTAssertTrue(
            exactOverride.acknowledgedRisk.warningMessage
                .localizedCaseInsensitiveContains("corrupt")
        )
    }

    func testExecutionRequiresExactPriorLibraryBackupOrUndo() throws {
        let fixture = try makeFixture()
        assertRejected(
            fixture.request,
            current: fixture.current,
            activity: fixture.inactiveActivity,
            undo: nil,
            code: .priorBackupRequired
        )

        let wrongBackup = fixture.backup.replacing(
            sha256: "different"
        )
        XCTAssertThrowsError(
            try fixture.request.acceptPriorBackup(wrongBackup)
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalRequestError)?.code,
                .invalidPriorBackup
            )
        }

        let undo = try fixture.request.acceptPriorBackup(fixture.backup)
        let authorization = try fixture.request.authorizeExecution(
            currentTarget: fixture.current,
            activity: fixture.inactiveActivity,
            priorBackup: undo
        )
        XCTAssertEqual(
            authorization.priorBackupArtifactID,
            fixture.backup.id
        )
    }

    func testDataFailureCannotAuthorizeMetadataRemoval() throws {
        let fixture = try makeFixture(choice: .archive)
        let undo = try fixture.request.acceptPriorBackup(fixture.backup)
        let execution = try fixture.request.authorizeExecution(
            currentTarget: fixture.current,
            activity: fixture.inactiveActivity,
            priorBackup: undo
        )

        XCTAssertThrowsError(
            try execution.authorizeMetadataRemoval(
                after: execution.dataPhaseFailed()
            )
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalRequestError)?.code,
                .managedDataActionFailed
            )
        }

        let otherFixture = try makeFixture(choice: .archive)
        let otherUndo = try otherFixture.request.acceptPriorBackup(
            otherFixture.backup
        )
        let otherExecution = try otherFixture.request.authorizeExecution(
            currentTarget: otherFixture.current,
            activity: otherFixture.inactiveActivity,
            priorBackup: otherUndo
        )
        XCTAssertThrowsError(
            try execution.authorizeMetadataRemoval(
                after: otherExecution.dataPhaseSucceeded()
            )
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalRequestError)?.code,
                .dataPhaseResultMismatch
            )
        }

        let transactionID = UUID()
        let metadata = try execution.authorizeMetadataRemoval(
            after: execution.dataPhaseSucceeded(
                transactionID: transactionID
            )
        )
        XCTAssertEqual(metadata.requestID, fixture.request.requestID)
        XCTAssertEqual(metadata.applicationID, fixture.applicationID)
        XCTAssertEqual(
            metadata.applicationStorageID,
            fixture.applicationStorageID
        )
        XCTAssertEqual(metadata.dataTransactionID, transactionID)
        XCTAssertEqual(
            metadata.priorBackupArtifactID,
            fixture.backup.id
        )
    }

    private func makeFixture(
        choice: ApplicationRemovalDataChoice = .keep
    ) throws -> ApplicationRemovalFixture {
        let applicationID = UUID()
        let applicationStorageID = UUID()
        let repositoryVersion = LibraryVersionToken(
            revision: LibraryRevision(rawValue: 8),
            primarySHA256: "prior-library"
        )
        let profiles = [
            ApplicationRemovalProfileTarget(
                profileID: UUID(),
                profileStorageID: UUID(),
                profileName: "Personal",
                managedProfileRoot: DestructiveActionPathSnapshot(
                    canonicalURL: URL(
                        fileURLWithPath: "/managed/personal",
                        isDirectory: true
                    ),
                    fileIdentity: FileSystemObjectIdentity(
                        volumeID: 1,
                        fileID: 10
                    )
                ),
                externalPaths: [
                    ApplicationRemovalExternalPath(
                        role: .codexHome,
                        declaredPath: "/external/codex"
                    )
                ]
            ),
            ApplicationRemovalProfileTarget(
                profileID: UUID(),
                profileStorageID: UUID(),
                profileName: "Work",
                managedProfileRoot: DestructiveActionPathSnapshot(
                    canonicalURL: URL(
                        fileURLWithPath: "/managed/work",
                        isDirectory: true
                    ),
                    fileIdentity: FileSystemObjectIdentity(
                        volumeID: 1,
                        fileID: 11
                    )
                ),
                externalPaths: []
            ),
        ]
        let request = try ApplicationRemovalRequest(
            requestID: UUID(),
            sceneID: UUID(),
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            applicationName: "Chromium",
            profiles: profiles,
            dataChoice: choice,
            repositoryVersion: repositoryVersion
        )
        let current = ApplicationRemovalCurrentTarget(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            applicationName: "Chromium",
            profiles: profiles.reversed(),
            repositoryVersion: repositoryVersion
        )
        let inactive = ApplicationRemovalActivitySnapshot(
            profiles: profiles.map {
                ApplicationRemovalProfileActivity(
                    applicationID: applicationID,
                    applicationStorageID: applicationStorageID,
                    profileID: $0.profileID,
                    profileStorageID: $0.profileStorageID,
                    state: .inactive
                )
            }
        )
        let backup = LibraryRecoveryArtifact(
            id: UUID(),
            kind: .backup,
            reason: .destructiveRewrite,
            content: .currentLibrary,
            createdAt: Date(timeIntervalSince1970: 100),
            libraryURL: URL(fileURLWithPath: "/not-read/library.json"),
            byteCount: 42,
            sha256: "prior-library"
        )
        return ApplicationRemovalFixture(
            request: request,
            current: current,
            inactiveActivity: inactive,
            backup: backup,
            applicationID: applicationID,
            applicationStorageID: applicationStorageID
        )
    }

    private func assertRejected(
        _ request: ApplicationRemovalRequest,
        current: ApplicationRemovalCurrentTarget?,
        activity: ApplicationRemovalActivitySnapshot,
        undo: ApplicationRemovalPriorBackup?,
        expertOverride: ApplicationRemovalExpertOverrideAuthorization? = nil,
        code: ApplicationRemovalRequestError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try request.authorizeExecution(
                currentTarget: current,
                activity: activity,
                priorBackup: undo,
                expertOverride: expertOverride
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalRequestError)?.code,
                code,
                file: file,
                line: line
            )
        }
    }
}

private struct ApplicationRemovalFixture {
    let request: ApplicationRemovalRequest
    let current: ApplicationRemovalCurrentTarget
    let inactiveActivity: ApplicationRemovalActivitySnapshot
    let backup: LibraryRecoveryArtifact
    let applicationID: UUID
    let applicationStorageID: UUID

    func activity(
        state: ApplicationRemovalProfileActivity.State
    ) -> ApplicationRemovalActivitySnapshot {
        ApplicationRemovalActivitySnapshot(
            profiles: inactiveActivity.profiles.map {
                ApplicationRemovalProfileActivity(
                    applicationID: $0.applicationID,
                    applicationStorageID: $0.applicationStorageID,
                    profileID: $0.profileID,
                    profileStorageID: $0.profileStorageID,
                    state: state
                )
            }
        )
    }
}

private extension ApplicationRemovalCurrentTarget {
    func replacing(
        applicationStorageID: UUID? = nil,
        profiles: [ApplicationRemovalProfileTarget]? = nil,
        repositoryVersion: LibraryVersionToken? = nil
    ) -> ApplicationRemovalCurrentTarget {
        ApplicationRemovalCurrentTarget(
            applicationID: applicationID,
            applicationStorageID:
                applicationStorageID ?? self.applicationStorageID,
            applicationName: applicationName,
            profiles: profiles ?? self.profiles,
            repositoryVersion:
                repositoryVersion ?? self.repositoryVersion
        )
    }
}

private extension LibraryRecoveryArtifact {
    func replacing(sha256: String) -> LibraryRecoveryArtifact {
        LibraryRecoveryArtifact(
            id: id,
            kind: kind,
            reason: reason,
            content: content,
            createdAt: createdAt,
            libraryURL: libraryURL,
            byteCount: byteCount,
            sha256: sha256
        )
    }
}
