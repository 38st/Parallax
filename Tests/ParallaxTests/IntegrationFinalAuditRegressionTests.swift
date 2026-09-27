import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationFinalAuditRegressionTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ManagedApplication, LaunchProfile, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-INT-final-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: "Reviewed Space")
        let app = ManagedApplication(displayName: "Fixture", bundleIdentifier: "test.fixture",
            appPath: root.appendingPathComponent("Fixture.app").path, baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root)
        _ = try repository.save([app], expectedVersion: .missing)
        let processes = TestWorkspaceProcessState()
        processes.processInspections[7001] = .dead
        let registry = try ProfileActivityRegistry(applicationSupportURL: root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: processes)
        return (LibraryStore(repository: repository, profileActivityRegistry: registry, settings: AppSettings()), app, profile, root)
    }

    private func addOpeningReceipt(root: URL, app: ManagedApplication, profile: LaunchProfile) throws -> URL {
        let journal = try DurableLaunchActivityStore(applicationSupportURL: root)
        let id = UUID()
        try journal.createRequest(requestID: id, identity: .init(applicationID: app.id,
            applicationStorageID: app.storageID, profileID: profile.id, profileStorageID: profile.storageID),
            ownerProcess: .init(processIdentifier: 7001, startTimeSeconds: 20, startTimeMicroseconds: 0), allowsConcurrentProfile: true)
        try journal.markOpening(requestID: id)
        return journal.rootURL.appendingPathComponent(id.uuidString.lowercased())
    }

    func testSuccessfulClearSurvivesBusyFollowupAndExplainsCachedBlocker() throws {
        for hasOtherBlocker in [false, true] {
            let (store, app, profile, root) = try fixture()
            let receipt = try addOpeningReceipt(root: root, app: app, profile: profile)
            if hasOtherBlocker {
                let corrupt = try addOpeningReceipt(root: root, app: app, profile: profile)
                try Data("corrupt".utf8).write(to: corrupt.appendingPathComponent("opening.json"))
            }
            _ = try store.profileActivityRegistry.reconcileDurableActivity()
            let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
                processSnapshotter: FinalProcessProbe()))
            var rechecked = false
            XCTAssertTrue(store.confirmClearStuckLaunchRecord(request, processSnapshotter: FinalProcessProbe(), reconcileActivity: {
                rechecked = true
                XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path), "Clear must have completed before the failing recheck")
                throw DurableLaunchActivityStoreError.activityBusy
            }))
            XCTAssertTrue(rechecked)
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
            XCTAssertEqual(store.profileActivityRegistry.isActive(identity: request.identity), hasOtherBlocker)
            if hasOtherBlocker {
                let blockerDescription: String = String(localized: "Other launch records could not be verified.")
                XCTAssertEqual(store.errorMessage, String(localized: "The stuck launch record was cleared. The remaining state could not be re-checked yet. The last known blocker is: \(blockerDescription)"))
                XCTAssertNil(store.libraryOperationStatusMessage)
            } else {
                XCTAssertNil(store.errorMessage)
                XCTAssertEqual(store.libraryOperationStatusMessage, String(localized: "The stuck launch record was cleared, but the remaining state could not be re-checked yet. Space data was kept."))
            }
        }
    }

    func testNonLocalizedErrorsAreMappedAtInvocationAndConfirmation() throws {
        for error: any Error in [SecureManagedFileSystemError.rootIdentityChanged, EmptyLocalizedRecoveryError()] {
            let (store, app, profile, root) = try fixture()
            _ = try addOpeningReceipt(root: root, app: app, profile: profile)
            _ = try store.profileActivityRegistry.reconcileDurableActivity()
            XCTAssertNil(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
                processSnapshotter: FinalProcessProbe(failure: error)))
            XCTAssertEqual(store.errorMessage, StuckLaunchRecoveryError.changedOrActive.localizedDescription)
            let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
                processSnapshotter: FinalProcessProbe()))
            XCTAssertFalse(store.confirmClearStuckLaunchRecord(request, processSnapshotter: FinalProcessProbe(failure: error)))
            XCTAssertEqual(store.errorMessage, StuckLaunchRecoveryError.changedOrActive.localizedDescription)
        }
    }

    func testIneligibleCachedActionExplainsWhyNoConfirmationAppears() throws {
        for change in 0..<3 {
            let (store, app, profile, root) = try fixture()
            _ = try addOpeningReceipt(root: root, app: app, profile: profile)
            _ = try store.profileActivityRegistry.reconcileDurableActivity()
            XCTAssertTrue(store.canRequestStuckLaunchRecovery(for: app, profile: profile))
            switch change {
            case 0: store.isLibraryOperationInProgress = true
            case 1: store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
            default: store.applications[0].profiles[0].name = "Changed"
            }
            XCTAssertNil(store.stuckLaunchRecoveryRequest(for: app, profile: profile, processSnapshotter: FinalProcessProbe()))
            XCTAssertEqual(store.errorMessage, String(localized: "The launch record changed or is no longer eligible to be cleared. Review the space and try again."))
        }
    }

    func testAbsentPrimaryHasMissingFileGuidance() throws {
        let (store, _, _, _) = try fixture()
        try FileManager.default.removeItem(at: XCTUnwrap(store.libraryPrimaryURL))
        store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
        XCTAssertTrue(store.isPrimaryMissing)
        XCTAssertEqual(store.libraryRecoveryDetail, String(localized: "The library file is missing. Restore a verified backup to retry recovery of pending operations."))
    }

    func testDanglingPrimarySymlinkHasNeutralGuidance() throws {
        let (store, _, _, root) = try fixture()
        let primary = try XCTUnwrap(store.libraryPrimaryURL)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createSymbolicLink(at: primary, withDestinationURL: root.appendingPathComponent("absent-target"))
        store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
        XCTAssertFalse(store.isPrimaryMissing)
        XCTAssertFalse(store.canRestoreLibraryBackup)
        XCTAssertEqual(store.libraryRecoveryDetail, String(localized: "Parallax has disabled library changes to protect the original data."))
    }

    func testSpanishKeychainProductNameIsCapitalized() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Parallax/Resources/es.lproj")
        for name in ["Localizable.strings", "Localizable.stringsdict"] {
            let contents = try String(contentsOf: resources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(contents.contains("llavero"), name)
        }
    }
}

private struct FinalProcessProbe: WorkspaceLaunchProcessProvenanceInspecting {
    var failure: (any Error)?
    func snapshot(expectedApplication: WorkspaceApplicationBundleIdentity) throws -> WorkspaceProcessSnapshot {
        if let failure { throw failure }
        return .init(expectedApplication: expectedApplication, processes: [])
    }
    func inspectReturnedProcess(processIdentifier: Int32, expectedApplication: WorkspaceApplicationBundleIdentity) -> WorkspaceProcessIdentityInspection {
        .indeterminate
    }
}

private struct EmptyLocalizedRecoveryError: LocalizedError {}
