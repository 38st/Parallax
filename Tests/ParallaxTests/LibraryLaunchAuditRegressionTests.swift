import Foundation
import XCTest

@testable import Parallax

@MainActor
final class LibraryLaunchAuditRegressionTests: XCTestCase {
    func fixture() throws -> (LibraryStore, ManagedApplication, LaunchProfile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: "Work")
        let app = ManagedApplication(
            displayName: "Audit", appPath: root.appendingPathComponent("Audit.app").path,
            profiles: [profile])
        let settings = AppSettings()
        settings.defaultBaseStoragePath = root.appendingPathComponent("Profiles").path
        let registry = ProfileActivityRegistry()
        let secrets = AuditSecretStore()
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: root),
            repository: LibraryRepository(applicationSupportURL: root),
            profileActivityRegistry: registry, launcher: AuditNoopLauncher(),
            launchConfigurationCompiler: LaunchConfigurationCompiler(
                activityProvider: registry,
                identity: ChildEnvironmentIdentity(
                    homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path),
                processEnvironment: [:], secretResolver: secrets),
            secretStore: secrets, settings: settings)
        store.applications = [app]
        return (store, app, profile)
    }

    func testBookkeepingDoesNotInvalidatePendingConfirmation() throws {
        let (store, app, profile) = try fixture()
        let source = store.launchConfigurationSource(
            application: app, profile: profile, requestID: UUID())
        let request = ImmutableLaunchRequest(
            sceneID: store.sceneID, applicationName: app.displayName, profileName: profile.name,
            configurationSnapshot: source,
            configurationFingerprint: LaunchConfigurationCompiler.configurationFingerprint(
                for: source))
        _ = store.launchRequests.submit(request, policy: .rejectNew)
        let priorVersion = store.libraryVersionToken
        store.recordAcceptedLaunch(
            applicationID: app.id, profileID: profile.id, profileName: profile.name)
        XCTAssertNotNil(store.applications.first?.profiles.first?.lastLaunchedAt)
        XCTAssertNotEqual(store.libraryVersionToken, priorVersion)
        XCTAssertNil(store.errorMessage)
        let resolution = store.launchRequests.confirm(
            sceneID: store.sceneID, requestID: request.requestID,
            currentTarget: store.currentLaunchTarget(for: request))
        guard case .confirmed = resolution else {
            return XCTFail("Bookkeeping is not a launch configuration edit: \(resolution)")
        }
    }

    func testAcceptedLaunchDuringDataOperationDoesNotSetError() throws {
        let (store, app, profile) = try fixture()
        store.isProfileDataOperationRunning = true
        store.recordAcceptedLaunch(
            applicationID: app.id, profileID: profile.id, profileName: profile.name)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.applications.first?.profiles.first?.lastLaunchedAt)
    }

    func testActivityChangeInvalidatesCachedHealth() async throws {
        let (store, app, profile) = try fixture()
        _ = await store.refreshHealthItems(for: app, profile: profile)
        let lease = try store.profileActivityRegistry.acquire(
            identity: ProfileActivityIdentity(
                applicationID: app.id, applicationStorageID: app.storageID, profileID: profile.id,
                profileStorageID: profile.storageID),
            requestID: UUID()
        )
        defer { lease.release() }
        XCTAssertFalse(
            store.healthItems(for: app, profile: profile).contains {
                $0.label == String(localized: "Storage inactive") && $0.isHealthy
            })
    }

    func testGenericTerminalFailureReleasesRetainedSession() throws {
        let (store, app, profile) = try fixture()
        let harness = LifecycleHarness()
        let identity = ProfileActivityIdentity(
            applicationID: app.id, applicationStorageID: app.storageID, profileID: profile.id,
            profileStorageID: profile.storageID)
        let id = UUID()
        let launch = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: id, identity: identity),
            activityRegistry: harness.registry, eventHandler: { _ in })
        store.activeTrackedLaunches[id] = launch
        launch.didFail(AuditLibraryLaunchError.failed)
        store.handleLaunchLifecycle(launch.currentLifecycle, profileName: profile.name)
        XCTAssertNil(store.activeTrackedLaunches[id])
    }

    func testUnavailableSettingsCompletesPreparedRequestAsCancelled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(
            production: .recoveryRequired(.container(.invalidURL("synthetic"))))
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: root),
            profileActivityRegistry: ProfileActivityRegistry(), launcher: AuditNoopLauncher(),
            launchConfigurationCompiler: LaunchConfigurationCompiler(
                processEnvironment: [:], secretResolver: AuditSecretStore()),
            secretStore: AuditSecretStore(), settings: settings)
        let harness = LifecycleHarness()
        let prepared = harness.prepared(requestID: UUID())
        let profile = LaunchProfile(
            id: prepared.profileID, storageID: prepared.profileStorageID, name: "Work")
        let app = ManagedApplication(
            id: prepared.applicationID, storageID: prepared.applicationStorageID,
            displayName: "Audit", appPath: prepared.applicationURL.path, profiles: [profile])
        let source = store.launchConfigurationSource(
            application: app, profile: profile, requestID: prepared.requestID)
        XCTAssertTrue(
            store.registerDirectLaunchIfNeeded(application: app, profile: profile, source: source))
        try store.openPreparedLaunch(
            prepared, profileName: profile.name, concurrentLaunchPolicy: .deny)
        XCTAssertEqual(store.launchRequests.status(for: prepared.requestID)?.state, .cancelled)
    }

    func testManualOpenAgainResetsRecoveryBudget() throws {
        let (store, app, profile) = try fixture()
        store.settings.confirmBeforeLaunch = true
        let key = ManagedAppRecoveryKey(
            applicationStorageID: app.storageID, profileStorageID: profile.storageID)
        for _ in 0..<3 {
            _ = try store.managedAppRecoveryLedger.decision(
                for: key, confirmedCrashAt: Date(timeIntervalSince1970: 100))
        }
        let entry = LaunchHistoryEntry(
            requestID: UUID(), applicationID: app.id, applicationStorageID: app.storageID,
            profileID: profile.id, profileStorageID: profile.storageID,
            applicationName: app.displayName, applicationBundleIdentifier: nil,
            profileName: profile.name, requestedAt: Date(), state: .closed)
        XCTAssertTrue(store.reopen(entry, from: app))
        XCTAssertEqual(
            try store.managedAppRecoveryLedger.decision(
                for: key, confirmedCrashAt: Date(timeIntervalSince1970: 101)),
            .retry(after: 2, attempt: 1, maximumAttempts: 2))
    }

    func testRecoveryIgnoresNamesNotesAndBookkeeping() throws {
        let (store, app, profile) = try fixture()
        var renamed = app
        renamed.displayName = "Renamed"
        renamed.profiles[0].name = "Renamed space"
        renamed.profiles[0].notes = "Edited notes"
        renamed.profiles[0].lastLaunchedAt = Date(timeIntervalSince1970: 100)
        store.applications = [renamed]
        XCTAssertNotNil(store.recoveryTarget(application: app, profile: profile))
    }

    func testHealthKeepsPriorResultAndIgnoresMetadataEdits() async throws {
        let (store, app, profile) = try fixture()
        let prior = await store.refreshHealthItems(for: app, profile: profile)
        var draft = profile
        draft.notes = "Typing notes"
        draft.name = "Renamed"
        XCTAssertEqual(store.healthItems(for: app, profile: draft).map(\.label), prior.map(\.label))
        XCTAssertTrue(store.healthInspectionTasks.isEmpty)
        draft.argumentsText = "--different"
        XCTAssertEqual(store.healthItems(for: app, profile: draft).map(\.label), prior.map(\.label))
        for task in store.healthInspectionTasks.values { await task.value }
    }

    func testRecoveryRejectsRemovedOrChangedTargetAfterBackoff() throws {
        let (store, app, profile) = try fixture()
        store.applications = []
        XCTAssertNil(store.recoveryTarget(application: app, profile: profile))
        var changed = app
        changed.profiles[0].argumentsText = "--changed"
        store.applications = [changed]
        XCTAssertNil(store.recoveryTarget(application: app, profile: profile))
        store.applications = [app]
        XCTAssertEqual(store.recoveryTarget(application: app, profile: profile)?.profile, profile)
    }

    func testHealthInspectionIncludesDraftPaths() throws {
        let (store, app, original) = try fixture()
        var draft = original
        draft.argumentsText = "--user-data-dir=/draft/location"
        draft.isolationOwnership.userData = .explicit
        let source = store.healthInspectionSource(for: app, profile: draft)
        XCTAssertTrue(
            source.profileInputs.contains { input in
                input.isolationPaths.contains { $0.source == .external("/draft/location") }
            })
    }

    func testDirectRecoveryReportsPendingConfirmationInsteadOfSilentlyDropping() throws {
        let (store, app, profile) = try fixture()
        let first = store.launchConfigurationSource(
            application: app, profile: profile, requestID: UUID())
        let request = ImmutableLaunchRequest(
            sceneID: store.sceneID, applicationName: app.displayName, profileName: profile.name,
            configurationSnapshot: first,
            configurationFingerprint: LaunchConfigurationCompiler.configurationFingerprint(
                for: first))
        _ = store.launchRequests.submit(request, policy: .rejectNew)
        let second = store.launchConfigurationSource(
            application: app, profile: profile, requestID: UUID())
        XCTAssertFalse(
            store.registerDirectLaunchIfNeeded(application: app, profile: profile, source: second))
        XCTAssertNotNil(store.errorMessage)
    }

    func testNewOverridePromptCancelsPreviousOpeningRequest() async throws {
        let (store, app, profile) = try fixture()
        let root = URL(fileURLWithPath: app.appPath).deletingLastPathComponent()
        let bundle = try ValidApplicationBundleFixture.create(in: root, name: "Audit.app")
        func source() -> LaunchConfigurationSource {
            LaunchConfigurationSource(
                requestID: UUID(), applicationID: app.id, applicationStorageID: app.storageID,
                profileID: profile.id, profileStorageID: profile.storageID,
                configurationRevision: 1, applicationURL: bundle.url,
                expectedBundleIdentifier: bundle.bundleIdentifier, configuredBaseRoot: root.path,
                argumentsText: "--label 'unfinished", environmentText: "",
                isolationOwnership: .explicit, childEnvironmentPolicy: .safeDefault,
                sensitiveEnvironmentKeys: [])
        }
        let first = source()
        let second = source()
        for current in [first, second] {
            XCTAssertTrue(
                store.registerDirectLaunchIfNeeded(
                    application: app, profile: profile, source: current))
            store.schedulePreparedLaunch(
                current, profileName: profile.name, override: nil, concurrentLaunchPolicy: .deny)
            let preparation = try XCTUnwrap(store.launchPreparationTasks[current.requestID])
            await preparation.value
            XCTAssertEqual(
                store.pendingLaunchDiagnosticRequest?.source.requestID, current.requestID)
        }
        XCTAssertEqual(store.launchRequests.status(for: first.requestID)?.state, .cancelled)
        store.cancelLaunchDiagnosticOverride()
    }
}

private enum AuditLibraryLaunchError: Error { case failed }
