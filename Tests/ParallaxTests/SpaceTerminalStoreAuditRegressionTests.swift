import Foundation
import XCTest
@testable import Parallax

final class SpaceTerminalStoreAuditRegressionTests: XCTestCase {
    @MainActor
    func testFailedHandoffDeletesCommandAndReleasesStorage() async throws {
        let (store, application, profile) = try fixture(preset: .codex)
        var commandURL: URL?
        await store.openTerminalInSpace(for: application, profile: profile, openCommand: { url in
            commandURL = url
            XCTAssertTrue(store.profileActivityRegistry.isStorageReserved(
                applicationStorageID: application.storageID, profileStorageID: profile.storageID))
            throw CocoaError(.fileReadUnknown)
        })
        let url = try XCTUnwrap(commandURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertFalse(store.profileActivityRegistry.isStorageReserved(
            applicationStorageID: application.storageID, profileStorageID: profile.storageID))
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testClaudeHandoffUsesImplicitLaunchDirectoryWithoutChangingLibrary() async throws {
        let (store, application, profile) = try fixture(preset: .claude)
        let paths = try store.managedPaths(for: application, profile: profile)
        var opened = false
        await store.openTerminalInSpace(for: application, profile: profile, openCommand: { url in
            opened = true
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let script = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(script.contains("CLAUDE_CONFIG_DIR='\(paths.claudeConfig.url.path)'"))
            for path in [paths.userData.url, paths.claudeConfig.url] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            }
        })
        XCTAssertTrue(opened, store.errorMessage ?? "No Terminal handoff")
        XCTAssertEqual(store.applications, [application])
        XCTAssertFalse(store.profileActivityRegistry.isStorageReserved(
            applicationStorageID: application.storageID, profileStorageID: profile.storageID))
    }

    @MainActor
    func testReservedStorageNeverReachesTerminalOpener() async throws {
        let (store, application, profile) = try fixture(preset: .codex)
        let reservation = try store.profileActivityRegistry.acquireDataOperationLease(identities: [
            .init(applicationID: application.id, applicationStorageID: application.storageID,
                  profileID: profile.id, profileStorageID: profile.storageID)
        ])
        defer { reservation.release() }
        await store.openTerminalInSpace(for: application, profile: profile, openCommand: { _ in XCTFail("Reserved space opened") })
        XCTAssertEqual(store.errorMessage, String(localized: "Parallax cannot open Terminal for “\(profile.name)” while its storage is reserved by a data operation. Wait for the operation to finish."))
    }

    @MainActor
    func testImportedConfigurationAndUnsavedDraftNeverReachTerminalOpener() async throws {
        let (store, application, profile) = try fixture(preset: .codex)
        var imported = profile
        imported.markLaunchConfigurationImported()
        var importedApplication = application
        importedApplication.profiles = [imported]
        store.applications = [importedApplication]
        var reviewed = false
        await store.openTerminalInSpace(for: importedApplication, profile: imported,
            reviewImportedConfiguration: { _ in reviewed = true; return false }, openCommand: { _ in
                XCTFail("Unreviewed import opened")
            })
        XCTAssertTrue(reviewed)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.applications[0].profiles[0].launchConfigurationTrust, .importedPendingReview)
        store.applications = [application]
        store.errorMessage = nil
        var draft = profile
        draft.environmentText = "CODEX_HOME=/edited/path"
        store.rememberProfileEditingDraft(applicationID: application.id, draft: draft, baseline: profile,
            baselineVersion: .missing, stagedKeychainReferences: [], pendingKeychainDeletionReferences: [])
        await store.openTerminalInSpace(for: application, profile: profile, openCommand: { _ in XCTFail("Unsaved draft opened") })
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRunningSpaceCanOpenTerminal() async throws {
        let (store, application, profile) = try fixture(preset: .codex)
        let launch = try store.profileActivityRegistry.acquireLaunchLease(identity: .init(
            applicationID: application.id, applicationStorageID: application.storageID,
            profileID: profile.id, profileStorageID: profile.storageID), requestID: UUID())
        defer { launch.release() }
        var opened = false
        await store.openTerminalInSpace(for: application, profile: profile, openCommand: { url in
            opened = true
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        })
        XCTAssertTrue(opened, store.errorMessage ?? "Terminal did not open")
    }

    @MainActor
    func testMovedApplicationDoesNotPreventTerminal() async throws {
        let (store, application, profile) = try fixture(preset: .codex)
        try FileManager.default.removeItem(atPath: application.appPath)
        var opened = false
        await store.openTerminalInSpace(for: application, profile: profile, openCommand: { url in
            opened = true
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        })
        XCTAssertTrue(opened, store.errorMessage ?? "Terminal did not open")
    }

    @MainActor
    func testUnrelatedSaveDuringPreparationDoesNotPreventTerminal() async throws {
        let (store, application, profile) = try fixture(preset: .codex, usesRepository: true)
        var opened = false
        await store.openTerminalInSpace(for: application, profile: profile, prepareCommand: { source, preset, name in
            let command = try SpaceTerminalService(activityRegistry: store.profileActivityRegistry)
                .prepare(source, preset: preset, profileName: name)
            var candidate = store.applications
            candidate[0].profiles[0].lastLaunchedAt = Date(timeIntervalSince1970: 20)
            XCTAssertTrue(store.commit(candidate, selectedApplicationID: nil, selectedProfileID: nil))
            XCTAssertNotEqual(store.launchConfigurationSource(application: application, profile: profile,
                requestID: source.requestID).configurationRevision, source.configurationRevision)
            return command
        }, openCommand: { url in
            opened = true
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        })
        XCTAssertTrue(opened, store.errorMessage ?? "Terminal did not open")
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testChangedConfigurationAfterPreparationDeletesCommandAndDoesNotOpen() async throws {
        let (store, application, profile) = try fixture(preset: .codex)
        var commandURL: URL?
        await store.openTerminalInSpace(for: application, profile: profile, prepareCommand: { source, preset, name in
            let command = try SpaceTerminalService(activityRegistry: store.profileActivityRegistry)
                .prepare(source, preset: preset, profileName: name)
            commandURL = command.url
            store.applications[0].profiles[0].environmentText = "CODEX_HOME=/changed"
            return command
        }, openCommand: { _ in XCTFail("Changed configuration opened") })
        let url = try XCTUnwrap(commandURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.errorMessage, SpaceTerminalError.changed.localizedDescription)
    }

    @MainActor
    func testImportedSpaceCanBeApprovedFromTerminalAction() async throws {
        let (store, original, originalProfile) = try fixture(preset: .codex)
        var profile = originalProfile
        profile.markLaunchConfigurationImported()
        var application = original
        application.profiles = [profile]
        store.applications = [application]
        var reviews = 0
        var opened = false
        await store.openTerminalInSpace(for: application, profile: profile,
            reviewImportedConfiguration: { _ in reviews += 1; return true }, openCommand: { url in
                opened = true
                try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            })
        XCTAssertEqual(reviews, 1)
        XCTAssertTrue(opened, store.errorMessage ?? "Terminal did not open")
        guard case .importedApproved = store.applications[0].profiles[0].launchConfigurationTrust else {
            return XCTFail("Terminal review was not saved")
        }
        XCTAssertFalse(store.isShowingImportedLaunchReview)
        XCTAssertFalse(store.isShowingLaunchConfirmation)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testImportedReviewCannotApproveChangedConfiguration() async throws {
        let (store, original, originalProfile) = try fixture(preset: .codex)
        var profile = originalProfile
        profile.markLaunchConfigurationImported()
        var application = original
        application.profiles = [profile]
        store.applications = [application]
        await store.openTerminalInSpace(for: application, profile: profile,
            reviewImportedConfiguration: { _ in
                store.applications[0].profiles[0].environmentText = "CODEX_HOME=/changed"
                return true
            }, openCommand: { _ in XCTFail("Changed imported configuration opened") })
        XCTAssertEqual(store.applications[0].profiles[0].launchConfigurationTrust, .importedPendingReview)
        XCTAssertEqual(store.errorMessage, SpaceTerminalError.changed.localizedDescription)
    }

    @MainActor
    private func fixture(preset: AppPreset, usesRepository: Bool = false) throws -> (LibraryStore, ManagedApplication, LaunchProfile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-Terminal-Store-Audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let suite = "Parallax-Terminal-Store-Audit-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: root.appendingPathComponent("Support")),
            repository: usesRepository ? LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support")) : nil,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings(userDefaults: defaults))
        var profile = LaunchProfile(name: "Work")
        if preset == .codex { profile.isolationOwnership.codexHome = .generated }
        var application = ManagedApplication(displayName: "Fixture", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, baseStoragePath: root.appendingPathComponent("Storage").path, profiles: [profile])
        application.preset = preset
        store.applications = [application]
        return (store, application, profile)
    }
}
