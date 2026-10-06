import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationFollowupAuditRegressionTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ManagedApplication, LaunchProfile, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-INT-review-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: "Reviewed Space")
        let app = ManagedApplication(displayName: "Fixture", bundleIdentifier: "test.fixture",
            appPath: root.appendingPathComponent("Fixture.app").path, baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root)
        _ = try repository.save([app], expectedVersion: .missing)
        let state = TestWorkspaceProcessState()
        state.processInspections[7001] = .dead
        let registry = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler(), processInspector: state)
        let store = LibraryStore(repository: repository, profileActivityRegistry: registry, settings: AppSettings())
        return (store, app, profile, root)
    }

    private func addOpeningReceipt(root: URL, app: ManagedApplication, profile: LaunchProfile) throws -> UUID {
        let journal = try DurableLaunchActivityStore(applicationSupportURL: root)
        let id = UUID()
        try journal.createRequest(requestID: id, identity: .init(applicationID: app.id,
            applicationStorageID: app.storageID, profileID: profile.id, profileStorageID: profile.storageID),
            ownerProcess: .init(processIdentifier: 7001, startTimeSeconds: 20, startTimeMicroseconds: 0), allowsConcurrentProfile: true)
        try journal.markOpening(requestID: id)
        return id
    }

    func testPresentPrimaryWithoutCapturedBytesHasNeutralRecoveryGuidance() throws {
        let (store, _, _, _) = try fixture()
        store.loadState = .recoveryRequired(originalBytes: nil, message: "Pending operation needs recovery")
        XCTAssertFalse(store.isPrimaryMissing)
        XCTAssertFalse(store.canRestoreLibraryBackup)
        XCTAssertEqual(store.libraryRecoveryDetail, String(localized: "Parallax has disabled library changes to protect the original data."))
    }

    func testSettingsDecodePreservesChosenTemplateName() throws {
        var work = ProfileTemplate.defaults[1]
        work.name = "Research 🔬"
        let state = SettingsState(profileTemplates: [work], defaultBaseStoragePath: "", confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: true, appearance: .system, profileVisualIdentities: [:])
        XCTAssertEqual(try SettingsState(document: state.document(revision: .zero)), state)
    }

    func testConfirmationMapsUnverifiableProcessesToLocalizedRecoveryError() throws {
        let (store, app, profile, root) = try fixture()
        _ = try addOpeningReceipt(root: root, app: app, profile: profile)
        _ = try store.profileActivityRegistry.reconcileDurableActivity()
        let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
            processSnapshotter: FollowupProcessProbe()))
        XCTAssertFalse(store.confirmClearStuckLaunchRecord(request,
            processSnapshotter: FollowupProcessProbe(unavailable: true)))
        XCTAssertEqual(store.errorMessage, StuckLaunchRecoveryError.changedOrActive.localizedDescription)
    }

    func testMenuAvailabilityUsesCachedReceiptEvidenceAndInvocationRechecks() throws {
        let (store, app, profile, root) = try fixture()
        let id = try addOpeningReceipt(root: root, app: app, profile: profile)
        XCTAssertFalse(store.canRequestStuckLaunchRecovery(for: app, profile: profile))
        _ = try store.profileActivityRegistry.reconcileDurableActivity()
        XCTAssertTrue(store.canRequestStuckLaunchRecovery(for: app, profile: profile))
        let journal = try DurableLaunchActivityStore(applicationSupportURL: root)
        let opening = journal.rootURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent("opening.json")
        try FileManager.default.removeItem(at: opening)
        for _ in 0..<20 {
            XCTAssertTrue(store.canRequestStuckLaunchRecovery(for: app, profile: profile), "Rendering must use the cached snapshot")
        }
        XCTAssertNil(store.stuckLaunchRecoveryRequest(for: app, profile: profile, processSnapshotter: FollowupProcessProbe()))
        XCTAssertEqual(store.errorMessage, StuckLaunchRecoveryError.changedOrActive.localizedDescription)
    }

    func testInvocationMapsProcessFailureAndConfirmationNamesSpace() throws {
        let (store, app, profile, root) = try fixture()
        _ = try addOpeningReceipt(root: root, app: app, profile: profile)
        _ = try store.profileActivityRegistry.reconcileDurableActivity()
        XCTAssertNil(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
            processSnapshotter: FollowupProcessProbe(unavailable: true)))
        XCTAssertEqual(store.errorMessage, StuckLaunchRecoveryError.changedOrActive.localizedDescription)
        let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
            processSnapshotter: FollowupProcessProbe()))
        XCTAssertEqual(request.profileName, profile.name)
        XCTAssertTrue(request.confirmationTitle.contains(profile.name))
    }

    func testClearingOneReceiptReportsRemainingAmbiguousBlocker() throws {
        let (store, app, profile, root) = try fixture()
        _ = try addOpeningReceipt(root: root, app: app, profile: profile)
        let corruptID = try addOpeningReceipt(root: root, app: app, profile: profile)
        let journal = try DurableLaunchActivityStore(applicationSupportURL: root)
        let corruptURL = journal.rootURL.appendingPathComponent(corruptID.uuidString.lowercased()).appendingPathComponent("opening.json")
        try Data("broken".utf8).write(to: corruptURL)
        _ = try store.profileActivityRegistry.reconcileDurableActivity()
        let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile,
            processSnapshotter: FollowupProcessProbe()))
        XCTAssertTrue(store.confirmClearStuckLaunchRecord(request, processSnapshotter: FollowupProcessProbe()))
        XCTAssertTrue(store.profileActivityRegistry.isActive(identity: request.identity))
        XCTAssertNotNil(store.errorMessage, "The remaining blocker must be explained")
        XCTAssertNil(store.libraryOperationStatusMessage, "Do not display plain success while the space remains blocked")
        XCTAssertEqual(try Data(contentsOf: corruptURL), Data("broken".utf8))
    }

    func testAdditionalNetworkTrustKeysAreFlagged() {
        let keys = ["NODE_TLS_REJECT_UNAUTHORIZED", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "NO_PROXY", "no_proxy"]
        let review = ImportedLaunchTrust().review(for: .init(applicationID: UUID(), applicationStorageID: UUID(),
            applicationDisplayName: "Fixture", canonicalApplicationURL: URL(fileURLWithPath: "/Synthetic/Fixture.app"),
            expectedBundleIdentifier: "test.fixture", verifiedBundleIdentifier: "test.fixture",
            profileID: UUID(), profileStorageID: UUID(), profileName: "Fixture", configuredBaseRoot: "/Synthetic",
            argumentsText: "", environmentText: keys.map { "\($0)=fixture" }.joined(separator: "\n"),
            isolationOwnership: .explicit, childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [], isolationPaths: []))
        XCTAssertEqual(review.environmentEntries.count, keys.count)
        for entry in review.environmentEntries { XCTAssertTrue(entry.risks.contains(.networkTrust), entry.key) }
    }

    func testValidEnvironmentKeyWithUnrepresentableValueDoesNotMutateProfile() throws {
        let (store, app, profile, root) = try fixture()
        let primary = try XCTUnwrap(store.libraryPrimaryURL)
        let originalBytes = try Data(contentsOf: primary)
        store.selectedApplicationID = app.id
        store.selectedProfileID = profile.id
        let path = root.appendingPathComponent("line\nbreak")
        XCTAssertTrue(LaunchEnvironmentParser.parse("CODEX_HOME=").diagnostics.isEmpty)
        XCTAssertThrowsError(try LibraryStore.settingEnvironmentValue("CODEX_HOME", to: path.path, in: profile.environmentText)) { error in
            guard case LaunchConfigurationTextError.invalidEnvironmentEntry = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(store.profileDraftUsingCodexHome(path, profile: profile), profile)
        XCTAssertEqual(store.errorMessage, LaunchConfigurationTextError.invalidEnvironmentEntry.localizedDescription)
        store.errorMessage = nil
        store.useCodexHome(path, for: profile)
        XCTAssertEqual(store.errorMessage, LaunchConfigurationTextError.invalidEnvironmentEntry.localizedDescription)
        XCTAssertEqual(store.applications, [app])
        XCTAssertEqual(try Data(contentsOf: primary), originalBytes)
    }
}

private struct FollowupProcessProbe: WorkspaceLaunchProcessProvenanceInspecting {
    var unavailable = false
    func snapshot(expectedApplication: WorkspaceApplicationBundleIdentity) throws -> WorkspaceProcessSnapshot {
        if unavailable { throw WorkspaceProcessSnapshotError.processListUnavailable }
        return .init(expectedApplication: expectedApplication, processes: [])
    }
    func inspectReturnedProcess(processIdentifier: Int32, expectedApplication: WorkspaceApplicationBundleIdentity) -> WorkspaceProcessIdentityInspection {
        .indeterminate
    }
}
