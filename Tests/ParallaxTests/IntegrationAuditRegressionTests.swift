import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationAuditRegressionTests: XCTestCase {
    private func fixture(name: String = "Fixture", settings: AppSettings? = nil)
        throws -> (LibraryStore, ManagedApplication, LaunchProfile, URL)
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-INT-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: name, isolationOwnership: .init(userData: .generated, codexHome: .generated))
        let app = ManagedApplication(displayName: name, appPath: root.appendingPathComponent("Fixture.app").path,
                                     preset: .codex, baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root)
        _ = try repository.save([app], expectedVersion: .missing)
        let store = LibraryStore(repository: repository,
                                 profileActivityRegistry: ProfileActivityRegistry(), launcher: AuditNoopLauncher(),
                                 secretStore: AuditSecretStore(), settings: settings ?? AppSettings())
        return (store, app, profile, root)
    }

    func testEnvironmentRewriteReportsUnrepresentableValue() {
        for separator in ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            XCTAssertThrowsError(try LibraryStore.settingEnvironmentValue(
                "CODEX_HOME", to: "/folder" + separator + "INJECTED=yes", in: "CODEX_HOME=/old"))
        }
    }

    func testMissingPrimaryWithJournalCanRestoreVerifiedBackup() throws {
        let (store, app, profile, root) = try fixture()
        let repository = LibraryRepository(applicationSupportURL: root)
        let version = try XCTUnwrap(store.libraryVersionToken)
        let backupStore = try XCTUnwrap(store.backupStore)
        let primary = try XCTUnwrap(store.libraryPrimaryURL)
        let original = try Data(contentsOf: primary)
        _ = try backupStore.createBackup(of: original, reason: .destructiveRewrite)
        let destinationProfile = LaunchProfile(name: "Duplicate")
        var target = app
        target.profiles.append(destinationProfile)
        let prepared = try repository.prepare([target], expectedVersion: version)
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let source = try resolver.resolve(configuredBaseRoot: root.path,
            applicationStorageID: app.storageID, profileStorageID: profile.storageID)
        let destination = try resolver.resolve(configuredBaseRoot: root.path,
            applicationStorageID: app.storageID, profileStorageID: destinationProfile.storageID)
        try FileManager.default.createDirectory(at: source.profileRoot.url, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.profileRoot.url.appendingPathComponent("sentinel"))
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: root, transactionBoundary: { boundary in
            if boundary == .afterEffectBeforeRecord(.publishDestination) {
                throw CocoaError(.userCancelled)
            }
        })
        let request = ProfileDataTransactionRequest(transactionID: UUID(),
            identity: .init(applicationID: app.id, applicationStorageID: app.storageID,
                sourceProfileID: profile.id, sourceProfileStorageID: profile.storageID,
                destinationProfileID: destinationProfile.id, destinationProfileStorageID: destinationProfile.storageID),
            operation: .duplicate, source: source, destination: destination, externalDataHandling: .notConfigured)
        XCTAssertThrowsError(try coordinator.execute(request, preparedCommit: prepared, repository: repository, recoverOnFailure: false))
        try FileManager.default.removeItem(at: primary)
        let restarted = LibraryStore(repository: repository,
            backupStore: backupStore, profileDataTransactions: coordinator, profileActivityRegistry: ProfileActivityRegistry(),
            settings: AppSettings())
        guard case .recoveryRequired = restarted.loadState else { return XCTFail("Expected recovery") }
        XCTAssertNil(restarted.failedPrimaryBytes)
        XCTAssertNil(restarted.startOverAuthorization())
        XCTAssertTrue(restarted.restoreLatestVerifiedBackup(), restarted.errorMessage ?? "")
        XCTAssertEqual(restarted.applications, [app])
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
        XCTAssertEqual(try Data(contentsOf: primary), original)
        XCTAssertEqual(try Data(contentsOf: source.profileRoot.url.appendingPathComponent("sentinel")), Data("source".utf8))
    }

    func testRestoreForMissingPrimaryRefusesAReplacementThatAppeared() throws {
        let (_, _, _, root) = try fixture()
        let primary = root.appendingPathComponent("Parallax/library.json")
        let bytes = try Data(contentsOf: primary)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        let backups = LibraryBackupStore(fileSystem: fileSystem, recoveryRoot: root.appendingPathComponent("Recovery"))
        let artifact = try backups.createBackup(of: bytes, reason: .destructiveRewrite)
        let repository = LibraryRepository(applicationSupportURL: root)
        guard case .loaded(let original) = repository.load() else { return XCTFail("Expected loaded fixture") }
        _ = try repository.save([], expectedVersion: original.versionToken)
        let appearedBytes = try Data(contentsOf: primary)
        let store = LibraryStore(repository: repository, backupStore: backups,
            profileActivityRegistry: ProfileActivityRegistry(), fileSystem: fileSystem, settings: AppSettings())
        try FileManager.default.removeItem(at: primary)
        store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
        XCTAssertTrue(store.canRestoreLibraryBackup)
        let inserted = LaunchTestLocked(false)
        let backupPayloadPath = artifact.libraryURL.resolvingSymlinksInPath().path
        fileSystem.beforeOperation = { event in
            if event.operation == .readData,
                event.firstURL?.resolvingSymlinksInPath().path == backupPayloadPath, !inserted.value {
                inserted.mutate { $0 = true }
                try appearedBytes.write(to: primary)
            }
        }
        XCTAssertFalse(store.restoreLatestVerifiedBackup())
        XCTAssertTrue(inserted.value, "The primary must appear during backup preparation")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: primary), appearedBytes)
        XCTAssertNotEqual(appearedBytes, bytes)
    }

    func testMissingPrimaryRecoveryDoesNotTreatDanglingSymlinkAsAbsence() throws {
        let (store, _, _, root) = try fixture()
        let primary = try XCTUnwrap(store.libraryPrimaryURL)
        try FileManager.default.removeItem(at: primary)
        store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
        XCTAssertTrue(store.canRestoreLibraryBackup)
        try FileManager.default.createSymbolicLink(at: primary, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertFalse(store.canRestoreLibraryBackup)
        XCTAssertNil(store.startOverAuthorization())
    }

    func testMetadataExportMenuUsesLoadedLibraryAuthority() throws {
        let (store, _, _, _) = try fixture()
        XCTAssertTrue(store.canExportPortable(.libraryMetadata))
        store.loadState = .recoveryRequired(originalBytes: nil, message: "fixture")
        XCTAssertFalse(store.canExportPortable(.libraryMetadata))
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/Parallax/App/ParallaxApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".disabled(focusedStore?.canExportPortable(.libraryMetadata) != true)"))
    }

    func testRemovingSharedKeychainReferenceDoesNotDeleteSecret() async throws {
        let (store, app, profile, _) = try fixture()
        let reference = EnvironmentSecretReference()
        var shared = app
        shared.profiles[0].environmentText = "TOKEN=\(reference.token)"
        var other = LaunchProfile(name: "Other")
        other.environmentText = "TOKEN=\(reference.token)"
        shared.profiles.append(other)
        XCTAssertTrue(store.commit([shared], selectedApplicationID: nil, selectedProfileID: nil))
        let removed = await store.removeKeychainSecret(environmentKey: "TOKEN", for: shared.profiles[0])
        XCTAssertTrue(removed)
        XCTAssertEqual(store.applications[0].profiles[0].environmentText, "TOKEN=")
        XCTAssertEqual(store.applications[0].profiles[1], other)
        XCTAssertEqual(store.applications[0].profiles[0].id, profile.id)
    }

    func testInvalidSecretKeyDoesNotWriteOrMutateProfile() async throws {
        let (store, app, profile, _) = try fixture()
        let staged = await store.stageKeychainSecret("fixture", environmentKey: "TOKEN\nOTHER", in: profile)
        XCTAssertNil(staged)
        XCTAssertNotNil(store.errorMessage)
        let stored = await store.storeKeychainSecret("fixture", environmentKey: "TOKEN\nOTHER", for: profile)
        XCTAssertFalse(stored)
        XCTAssertEqual(store.applications, [app])
    }

    func testUnrepresentableCodexHomeDoesNotCommitOwnershipOrDraft() throws {
        let (store, app, profile, root) = try fixture()
        let version = store.libraryVersionToken
        store.selectedApplicationID = app.id
        store.selectedProfileID = profile.id
        let invalid = root.appendingPathComponent("invalid\nINJECTED=yes")
        XCTAssertEqual(store.profileDraftUsingCodexHome(invalid, profile: profile), profile)
        XCTAssertNotNil(store.errorMessage)
        store.errorMessage = nil
        store.useCodexHome(invalid, for: profile)
        XCTAssertEqual(store.applications, [app])
        XCTAssertEqual(store.libraryVersionToken, version)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLegacyFillerNamesAllowUnrelatedApplicationAndProfileEdits() throws {
        let (store, app, profile, _) = try fixture(name: "\u{3164}")
        var draft = app
        draft.appPath += ".relocated"
        XCTAssertTrue(store.applyApplicationEdit(draft: draft, baseline: app,
                                                baselineVersion: try XCTUnwrap(store.libraryVersionToken)))
        var profileDraft = profile
        profileDraft.notes = "Changed notes"
        XCTAssertTrue(store.applyProfileEdit(draft: profileDraft, baseline: profile, applicationID: app.id,
                                            baselineVersion: try XCTUnwrap(store.libraryVersionToken)))
        XCTAssertEqual(store.applications.first?.displayName, app.displayName)
        XCTAssertEqual(store.applications.first?.profiles.first?.notes, "Changed notes")
    }

    func testLegacyFillerNameAllowsPresetEditButChangedInvalidNamesFail() throws {
        let (store, app, profile, _) = try fixture(name: "\u{2800}")
        var draft = app
        draft.preset = .chrome
        let preview = try XCTUnwrap(store.presetChangePreview(for: app, targetPreset: .chrome))
        XCTAssertTrue(store.applyApplicationPresetEdit(draft: draft, baseline: app,
            baselineVersion: try XCTUnwrap(store.libraryVersionToken), preview: preview, refreshGeneratedValues: false))
        let current = try XCTUnwrap(store.applications.first)
        draft = current
        draft.displayName = "\u{3164}"
        XCTAssertFalse(store.applyApplicationEdit(draft: draft, baseline: current,
                                                 baselineVersion: try XCTUnwrap(store.libraryVersionToken)))
        var profileDraft = profile
        profileDraft.name = "\u{3164}"
        XCTAssertFalse(store.applyProfileEdit(draft: profileDraft, baseline: profile, applicationID: app.id,
                                             baselineVersion: try XCTUnwrap(store.libraryVersionToken)))
    }

    func testUnavailableOrBusySettingsTerminatesBothOverrideRequests() throws {
        for (concurrent, busy) in [(false, false), (true, false), (false, true), (true, true)] {
            let settings = busy ? AppSettings() : AppSettings(production: .recoveryRequired(.container(.invalidURL("synthetic"))))
            if busy { settings.registerPendingTextDraft(id: UUID(), commit: {}) }
            let (store, app, profile, _) = try fixture(settings: settings)
            let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
            XCTAssertTrue(store.registerDirectLaunchIfNeeded(application: app, profile: profile, source: source))
            let fingerprint = LaunchConfigurationCompiler.configurationFingerprint(for: source)
            if concurrent {
                store.pendingConcurrentLaunchRequest = .init(source: source, profileName: profile.name, fingerprint: fingerprint)
                store.isShowingConcurrentLaunchOverride = true
                store.confirmConcurrentLaunchOverride()
            } else {
                store.pendingLaunchDiagnosticRequest = .init(source: source, profileName: profile.name,
                                                              fingerprint: fingerprint, diagnostics: [])
                store.isShowingLaunchDiagnosticOverride = true
                store.confirmLaunchDiagnosticOverride()
            }
            guard case .failed(let message) = store.launchRequests.status(for: source.requestID)?.state else {
                XCTFail("An unavailable settings authority must terminate the request with an explanation")
                continue
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertNil(store.pendingConcurrentLaunchRequest)
            XCTAssertNil(store.pendingLaunchDiagnosticRequest)
            XCTAssertFalse(store.isShowingConcurrentLaunchOverride)
            XCTAssertFalse(store.isShowingLaunchDiagnosticOverride)
        }
    }

    func testDataOperationDiagnosticExplainsReservation() {
        let diagnostic = LaunchCompilerDiagnostic(code: .profileHealth(.storageReservedForDataOperation),
            severity: .error, isOverridable: false, sourceRange: nil, path: nil)
        XCTAssertEqual(diagnostic.message, ProfileActivityRegistryError.storageReservedForDataOperation.localizedDescription)
    }

    func testSettingsDecodePreservesCustomTemplateNames() throws {
        let defaults = ProfileTemplate.defaults
        var work = defaults[1]
        work.name = "Research 🔬"
        var throwaway = defaults[3]
        throwaway.name = "Scratch 🧪"
        throwaway.notes = "Custom temporary workspace."
        let inputs = [work, throwaway]
        for original in inputs {
            for field in 0..<5 {
                var template = original
                switch field {
                case 1: template.argumentsText = "--custom"
                case 2: template.environmentText = "CUSTOM=yes"
                case 3: template.notes += " custom"
                case 4: template = ProfileTemplate(name: template.name, notes: template.notes)
                default: break
                }
                let state = SettingsState(profileTemplates: [template], defaultBaseStoragePath: "", confirmBeforeLaunch: false,
                                          automaticallyRecoverCrashedApps: true, appearance: .system, profileVisualIdentities: [:])
                let loaded = try SettingsState(document: state.document(revision: .zero))
                XCTAssertEqual(loaded.profileTemplates, [template])
            }
        }
    }
}
