import Foundation
import XCTest
@testable import Parallax

final class PresetIntegrationAuditRegressionTests: XCTestCase {
    @MainActor
    func testConfirmedClaudeAndChromiumRequestsRetainEveryFingerprintField() throws {
        for preset in [AppPreset.claude, .chromium] {
            let fixture = try PresetIntegrationFixture(preset: preset)
            defer { fixture.remove() }
            fixture.store.settings.confirmBeforeLaunch = true
            fixture.store.launch(fixture.profile)
            XCTAssertTrue(fixture.store.isShowingLaunchConfirmation)
            let request = try XCTUnwrap(fixture.store.launchRequests.pendingConfirmation(in: fixture.store.sceneID))
            XCTAssertEqual(request.configurationSnapshot.preset, preset)
            XCTAssertEqual(request.configurationSnapshot.requiresClaudeConfigIsolation, preset == .claude)
            let target = fixture.store.currentLaunchTarget(for: request)
            XCTAssertEqual(fixture.store.launchRequests.confirm(sceneID: fixture.store.sceneID,
                requestID: request.requestID, currentTarget: target), .confirmed(request))
            var recoverySource = fixture.store.launchConfigurationSource(
                application: fixture.app, profile: fixture.profile, requestID: fixture.profile.id)
            recoverySource.configurationRevision = 0
            XCTAssertEqual(fixture.store.recoveryFingerprint(application: fixture.app, profile: fixture.profile),
                           LaunchConfigurationCompiler.configurationFingerprint(for: recoverySource))
        }
    }

    @MainActor
    func testAutomaticCustomEraSpacesRemainUnchangedUntilRecommendedSettings() async throws {
        for (bundle, preset) in [("org.mozilla.firefox", AppPreset.firefox),
            ("org.mozilla.firefoxdeveloperedition", .firefox), ("org.mozilla.nightly", .firefox),
            ("com.microsoft.VSCode", .visualStudioCode), ("com.microsoft.VSCodeInsiders", .visualStudioCode),
            ("com.vscodium", .visualStudioCode), ("com.todesktop.230313mzl4w4u92", .visualStudioCode),
            ("com.exafunction.windsurf", .visualStudioCode)] {
            let fixture = try PresetIntegrationFixture(preset: .automatic, bundleIdentifier: bundle)
            defer { fixture.remove() }
            let app = fixture.app
            let source = fixture.store.launchConfigurationSource(application: app, profile: fixture.profile, requestID: UUID())
            XCTAssertEqual(source.preset, preset)
            let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
            XCTAssertEqual(analysis.preview.arguments, [])
            XCTAssertTrue(analysis.isolation.presetFolders.isEmpty)
            XCTAssertNil(analysis.isolation.userData)
            let prepared = try await LaunchConfigurationCompiler(processEnvironment: [:]).prepare(source)
            XCTAssertEqual(prepared.arguments, [])
            XCTAssertTrue(prepared.isolation.managedVerificationPaths.isEmpty)
            XCTAssertEqual(app.profiles[0], fixture.profile)
        }
    }

    @MainActor
    func testRecommendedTemplatePreviewAndDuplicatePersistFreshGeneratedArguments() throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let fixture = try PresetIntegrationFixture(preset: preset)
            defer { fixture.remove() }
            let store = fixture.store
            let created = try store.profile(named: "Work", template: ProfileTemplate(name: "Work"), for: fixture.app)
            let folder: PresetIsolationFolder = preset == .firefox ? .firefoxProfile : .extensions
            let paths = try store.managedPaths(for: fixture.app, profile: created)
            XCTAssertEqual(folder.resolve(in: created.arguments).value, folder.managedPath(in: paths).url.path)
            XCTAssertEqual(folder.ownership(in: created.isolationOwnership), .generated)
            if preset == .firefox { XCTAssertTrue(created.arguments.contains("-no-remote")) }
            else { XCTAssertEqual(created.isolationOwnership.userData, .generated) }
            let preview = try XCTUnwrap(store.presetChangePreview(for: fixture.app, targetPreset: preset))
            let change = try XCTUnwrap(preview.changes.first { $0.kind == (preset == .firefox ? .firefoxProfile : .extensions) })
            XCTAssertEqual(change.disposition, .added)
            let service = PresetChangePreviewService()
            let applied = try service.applyingAuthorizedRefresh(preview,
                authorization: service.authorizeRefresh(preview, acknowledging: .applyListedGeneratedValueChanges),
                to: fixture.app)
            XCTAssertEqual(folder.resolve(in: applied.profiles[0].arguments).value, change.resultingValue)
            XCTAssertEqual(folder.ownership(in: applied.profiles[0].isolationOwnership), .generated)
            store.applications = [applied]
            store.selectedApplicationID = applied.id
            store.selectedProfileID = applied.profiles[0].id
            XCTAssertTrue(store.duplicateSelectedProfile(), store.errorMessage ?? "")
            let copy = try XCTUnwrap(store.applications[0].profiles.last)
            XCTAssertNotEqual(copy.storageID, applied.profiles[0].storageID)
            let copiedPaths = try store.managedPaths(for: applied, profile: copy)
            XCTAssertEqual(folder.resolve(in: copy.arguments).value, folder.managedPath(in: copiedPaths).url.path)
            XCTAssertNotEqual(folder.resolve(in: copy.arguments).value, change.resultingValue)
        }
    }

    @MainActor
    func testRecommendedSettingsPreserveExplicitOptionsButDuplicateReplacesThem() throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let fixture = try PresetIntegrationFixture(preset: preset)
            defer { fixture.remove() }
            let folder: PresetIsolationFolder = preset == .firefox ? .firefoxProfile : .extensions
            var explicit = fixture.profile
            explicit.argumentsText = try folder.setting(fixture.root.appendingPathComponent("external").path, in: "-- file")
            let ordinary = try fixture.store.applyingRecommendedSettings(to: explicit, for: fixture.app)
            XCTAssertEqual(folder.resolve(in: ordinary.arguments).value, folder.resolve(in: explicit.arguments).value)
            XCTAssertEqual(folder.ownership(in: ordinary.isolationOwnership), .explicit)
            let duplicate = try fixture.store.applyingRecommendedSettings(to: explicit.duplicatedWithFreshIdentity(),
                for: fixture.app, replacingExistingIsolation: true)
            XCTAssertEqual(folder.ownership(in: duplicate.isolationOwnership), .generated)
            XCTAssertNotEqual(folder.resolve(in: duplicate.arguments).value, folder.resolve(in: explicit.arguments).value)
            XCTAssertEqual(Array(duplicate.arguments.suffix(2)), ["--", "file"])
        }
    }

    @MainActor
    func testFirefoxSelectionSurvivesRecommendedSettingsAndDuplicateStartsFresh() throws {
        let fixture = try PresetIntegrationFixture(preset: .firefox)
        defer { fixture.remove() }
        for (arguments, environment) in [("-P work", ""), ("", "XRE_PROFILE_PATH=/external")] {
            let selected = LaunchProfile(name: "Selected", argumentsText: arguments, environmentText: environment)
            let retained = try fixture.store.applyingRecommendedSettings(to: selected, for: fixture.app)
            XCTAssertEqual(retained.argumentsText, arguments)
            XCTAssertEqual(retained.environmentText, environment)
            let duplicate = try fixture.store.applyingRecommendedSettings(to: selected.duplicatedWithFreshIdentity(),
                for: fixture.app, replacingExistingIsolation: true)
            XCTAssertFalse(PresetIsolationFolder.hasFirefoxSelection(argumentsText: duplicate.argumentsText,
                                                                      environmentText: duplicate.environmentText))
            XCTAssertEqual(duplicate.isolationOwnership.firefoxProfile, .generated)
            XCTAssertNotNil(PresetIsolationFolder.firefoxProfile.resolve(in: duplicate.arguments).value)
        }
    }

    func testEditingGeneratedPresetPathMakesTheValueUserOwned() throws {
        for folder in PresetIsolationFolder.allCases {
            var profile = LaunchProfile(name: "Work", argumentsText: try folder.setting("/generated", in: ""))
            profile.isolationOwnership[keyPath: folder.ownershipKeyPath] = .generated
            profile.argumentsText = try folder.setting("/user-owned", in: profile.argumentsText)
            XCTAssertEqual(folder.ownership(in: profile.isolationOwnership), .explicit)
        }
    }

    func testPreviousOwnershipEncodingLoadsAndNewGeneratedOwnershipRoundTrips() throws {
        let prior = Data(#"{"userData":"generated","codexHome":"legacyUnknown"}"#.utf8)
        var ownership = try JSONDecoder().decode(ProfileIsolationOwnership.self, from: prior)
        XCTAssertEqual(ownership.firefoxProfile, .explicit)
        XCTAssertEqual(ownership.extensions, .explicit)
        let oldShape = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ownership)) as? [String: String])
        XCTAssertEqual(oldShape.count, 2)
        ownership.firefoxProfile = .generated
        ownership.extensions = .generated
        XCTAssertEqual(try JSONDecoder().decode(ProfileIsolationOwnership.self, from: JSONEncoder().encode(ownership)), ownership)
    }

    @MainActor
    func testRelocationRewritesGeneratedValuesAndInventoriesExplicitDependencies() throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let fixture = try PresetIntegrationFixture(preset: preset)
            defer { fixture.remove() }
            let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
                fileSystem: LocalFileSystem(), activityProvider: ProfileActivityRegistry())
            let folder: PresetIsolationFolder = preset == .firefox ? .firefoxProfile : .extensions
            var app = fixture.app
            app.profiles = [try fixture.store.applyingRecommendedSettings(to: fixture.profile, for: app)]
            let destination = fixture.root.appendingPathComponent("destination").path
            let result = try coordinator.relocatedApplication(app, sourceBaseRoot: fixture.base, destinationBaseRoot: destination)
            XCTAssertTrue(result.blockers.isEmpty)
            XCTAssertTrue(result.generated.contains { $0.field == (preset == .firefox ? .firefoxProfile : .extensions) })
            XCTAssertTrue(try XCTUnwrap(folder.resolve(in: result.application.profiles[0].arguments).value).contains("destination/"))
            let paths = try fixture.store.managedPaths(for: app, profile: fixture.profile)
            let applicationPaths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolveApplication(
                configuredBaseRoot: fixture.base, applicationStorageID: app.storageID)
            for inside in [paths.profileRoot.url, applicationPaths.applicationArchiveRoot.url.appendingPathComponent("archive")] {
                app.profiles[0].argumentsText = try folder.setting(inside.path, in: "")
                app.profiles[0].isolationOwnership[keyPath: folder.ownershipKeyPath] = .explicit
                let blocked = try coordinator.relocatedApplication(app, sourceBaseRoot: fixture.base, destinationBaseRoot: destination)
                XCTAssertTrue(blocked.blockers.contains(.configuredPathInsideManagedStorage))
            }
            app.profiles[0].argumentsText = try folder.setting(fixture.root.appendingPathComponent("external").path, in: "")
            let external = try coordinator.relocatedApplication(app, sourceBaseRoot: fixture.base, destinationBaseRoot: destination)
            XCTAssertEqual(external.external.count, 1)
            var other = fixture.app
            other = ManagedApplication(displayName: "Peer", appPath: fixture.app.appPath,
                preset: preset, baseStoragePath: fixture.base, profiles: [LaunchProfile(name: "Peer",
                    argumentsText: try folder.setting(paths.profileRoot.url.path, in: ""))])
            let source = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolveApplication(
                configuredBaseRoot: fixture.base, applicationStorageID: app.storageID)
            XCTAssertEqual(try coordinator.dependentProfileBlockers(in: [app, other], moving: app, source: source).count, 1)
        }
    }

    @MainActor
    func testRemovalDisclosureRevealAndHealthRespectManagedContainment() throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let fixture = try PresetIntegrationFixture(preset: preset)
            defer { fixture.remove() }
            let folder: PresetIsolationFolder = preset == .firefox ? .firefoxProfile : .extensions
            var profile = fixture.profile
            let paths = try fixture.store.managedPaths(for: fixture.app, profile: profile)
            profile.argumentsText = try folder.setting(folder.managedPath(in: paths).url.path, in: "")
            var app = fixture.app
            app.profiles = [profile]
            fixture.store.applications = [app]
            XCTAssertTrue(try fixture.store.applicationRemovalProfileTargets(app)[0].externalPaths.isEmpty)
            XCTAssertEqual(fixture.store.externalDataHandling(for: profile), .notConfigured)
            var revealed: String?
            XCTAssertTrue(fixture.store.revealPresetIsolationFolder(folder, for: app, profile: profile,
                revealManaged: { revealed = $0.url.path; return true }, revealExternal: { _ in XCTFail("Expected managed"); return false }))
            XCTAssertEqual(revealed, folder.managedPath(in: paths).url.path)
            if preset == .firefox {
                XCTAssertTrue(fixture.store.shouldShowUserDataActions(for: app, profile: profile))
                XCTAssertEqual(fixture.store.userDataPath(for: app, profile: profile), revealed)
            }
            let external = fixture.root.appendingPathComponent("external")
            profile.argumentsText = try folder.setting(external.path, in: "")
            app.profiles = [profile]
            fixture.store.applications = [app]
            XCTAssertEqual(try fixture.store.applicationRemovalProfileTargets(app)[0].externalPaths.count, 1)
            XCTAssertNotEqual(fixture.store.externalDataHandling(for: profile), .notConfigured)
            let recommended = try fixture.store.applyingRecommendedSettings(to: fixture.profile, for: app)
            XCTAssertFalse(fixture.store.warnings(for: app, profile: recommended).contains { $0.contains("share browser state") })
            XCTAssertNotEqual(SpaceSeparationSummary(application: app, profile: recommended).kind, .custom)
            XCTAssertNotEqual(SpaceSeparationSummary(application: app, profile: recommended).kind, .browsingData)
        }
    }
}

@MainActor
final class PresetIntegrationFixture {
    let root: URL
    let base: String
    let store: LibraryStore
    let profile: LaunchProfile
    let app: ManagedApplication

    init(preset: AppPreset, bundleIdentifier: String = "com.example.fixture", verification: LaunchIsolationVerification = LaunchIsolationVerification()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        base = root.appendingPathComponent("Profiles").path
        let bundle = try ValidApplicationBundleFixture.create(in: root, bundleIdentifier: bundleIdentifier)
        profile = LaunchProfile(name: "Work")
        app = ManagedApplication(displayName: "Fixture", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: preset, baseStoragePath: base, profiles: [profile])
        let settings = AppSettings()
        settings.defaultBaseStoragePath = base
        store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: root.appendingPathComponent("Library")),
            profileActivityRegistry: ProfileActivityRegistry(), isolationVerification: verification, settings: settings)
        store.applications = [app]
        store.selectedApplicationID = app.id
        store.selectedProfileID = profile.id
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
