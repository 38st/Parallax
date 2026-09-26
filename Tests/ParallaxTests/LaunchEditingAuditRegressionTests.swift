import XCTest

@testable import Parallax

final class LaunchEditingAuditRegressionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CFG-Editing-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testEditorIsolationEditsBecomeExplicitAndPersist() throws {
        let (store, application, baseline) = try fixture()
        var draft = baseline
        draft.argumentsText = "--user-data-dir=/external/user-data"
        draft.environmentText = "CODEX_HOME=/external/codex"
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: draft, baseline: baseline, applicationID: application.id,
                baselineVersion: try XCTUnwrap(store.libraryVersionToken)),
            store.errorMessage ?? "")
        let saved = try XCTUnwrap(store.applications.first?.profiles.first)
        XCTAssertEqual(saved.isolationOwnership, .explicit)
        guard
            case .loaded(let snapshot) = LibraryRepository(applicationSupportURL: root)
                .load()
        else {
            return XCTFail("Expected saved library")
        }
        XCTAssertEqual(
            snapshot.applications.first?.profiles.first?.isolationOwnership, .explicit)
    }

    @MainActor
    func testRecommendedOwnershipAndManagedValuesArePreserved() throws {
        let (store, application, baseline) = try fixture()
        let paths = try store.managedPaths(for: application, profile: baseline)
        var draft = baseline
        draft.argumentsText = LaunchArgumentParser.quote(
            "--user-data-dir=\(paths.userData.url.path)")
        draft.environmentText = "CODEX_HOME=\(paths.codexHome.url.path)"
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: draft, baseline: baseline, applicationID: application.id,
                baselineVersion: try XCTUnwrap(store.libraryVersionToken)),
            store.errorMessage ?? "")
        XCTAssertEqual(
            store.applications.first?.profiles.first?.isolationOwnership,
            baseline.isolationOwnership)
        let saved = try XCTUnwrap(store.applications.first?.profiles.first)
        var explicit = saved
        explicit.isolationOwnership = .explicit
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: explicit, baseline: saved, applicationID: application.id,
                baselineVersion: try XCTUnwrap(store.libraryVersionToken)),
            store.errorMessage ?? "")
        var recommended = explicit
        recommended.isolationOwnership = baseline.isolationOwnership
        recommended.argumentsText = "--user-data-dir=/old-generated-value"
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: recommended, baseline: explicit, applicationID: application.id,
                baselineVersion: try XCTUnwrap(store.libraryVersionToken)),
            store.errorMessage ?? "")
        XCTAssertEqual(
            store.applications.first?.profiles.first?.isolationOwnership,
            baseline.isolationOwnership)
    }

    @MainActor
    func testEditorSavesAreBlockedDuringDataOperations() throws {
        let (store, application, baseline) = try fixture()
        store.isProfileDataOperationRunning = true
        try assertEditsBlocked(
            store: store, application: application, profile: baseline)
    }

    @MainActor
    func testEditorSavesAreBlockedDuringSettingsRecovery() throws {
        let settings = AppSettings(
            production: .recoveryRequired(
                .container(.systemCall(operation: "fixture", code: EIO))))
        let (store, application, baseline) = try fixture(settings: settings)
        try assertEditsBlocked(
            store: store, application: application, profile: baseline)
    }

    @MainActor
    func testUnchangedHistoricalNamesDoNotConflictWithPeerRenames() throws {
        let (store, application, baseline) = try fixture(name: "  Cafe\u{301}  ")
        let version = try XCTUnwrap(store.libraryVersionToken)
        var peerApplication = application
        peerApplication.displayName = "Peer app"
        peerApplication.profiles[0].name = "Peer space"
        let snapshot = try LibraryRepository(applicationSupportURL: root).save(
            [peerApplication], expectedVersion: version)
        store.applications = snapshot.applications
        store.libraryVersionToken = snapshot.versionToken
        var draft = baseline
        draft.notes = "Local notes"
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: draft, baseline: baseline, applicationID: application.id,
                baselineVersion: version), store.errorMessage ?? "")
        XCTAssertEqual(store.applications.first?.profiles.first?.name, "Peer space")
        XCTAssertEqual(store.applications.first?.profiles.first?.notes, "Local notes")
        var appDraft = application
        appDraft.bundleIdentifier = "example.changed"
        XCTAssertTrue(
            store.applyApplicationEdit(
                draft: appDraft, baseline: application, baselineVersion: version),
            store.errorMessage ?? "")
        XCTAssertEqual(store.applications.first?.displayName, "Peer app")
    }

    @MainActor
    func testClaudeImplicitIsolationPreservesInvalidArgumentsAndReviewText()
        async throws
    {
        let (store, originalApplication, originalProfile) = try fixture()
        var application = originalApplication
        application.preset = .claude
        var profile = originalProfile
        profile.argumentsText = "--user-data-dir=/external 'unfinished"
        profile.environmentText =
            "# note\u{2028}DYLD_INSERT_LIBRARIES=/fixture\nCLAUDE_CONFIG_DIR="
        let source = store.launchConfigurationSource(
            application: application, profile: profile, requestID: UUID())
        XCTAssertEqual(source.argumentsText, profile.argumentsText)
        let paths = try store.managedPaths(for: application, profile: profile)
        XCTAssertEqual(
            source.environmentText,
            profile.environmentText + paths.claudeConfig.url.path)
        let analysis = await store.launchConfigurationCompiler.analyze(source)
        XCTAssertTrue(
            analysis.diagnostics.contains {
                $0.code == .parsing(.unsupportedControlCharacter)
            })

        profile.argumentsText = ""
        profile.environmentText = "SAFE=yes"
        let cleanSource = store.launchConfigurationSource(
            application: application, profile: profile, requestID: UUID())
        let cleanAnalysis = await store.launchConfigurationCompiler.analyze(cleanSource)
        let trustSource = store.importedLaunchTrustSource(
            application: application, profile: profile, analysis: cleanAnalysis,
            source: cleanSource)
        XCTAssertEqual(trustSource.argumentsText, cleanSource.argumentsText)
        XCTAssertEqual(trustSource.environmentText, cleanSource.environmentText)
        XCTAssertEqual(trustSource.isolationOwnership, cleanSource.isolationOwnership)
    }

    @MainActor
    func testClaudeManagedIsolationSurvivesOverridableErrors() async throws {
        let (store, originalApplication, originalProfile) = try fixture()
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        var application = originalApplication
        application.preset = .claude
        application.appPath = bundle.url.path
        application.bundleIdentifier = bundle.bundleIdentifier
        var profile = originalProfile
        profile.isolationOwnership = .explicit
        profile.argumentsText = "'unfinished"
        profile.environmentText = "export ANTHROPIC_BASE_URL=https://fixture.invalid"
        let paths = try store.managedPaths(for: application, profile: profile)
        let source = store.launchConfigurationSource(
            application: application, profile: profile, requestID: UUID())
        XCTAssertEqual(source.argumentsText, profile.argumentsText)
        XCTAssertEqual(source.isolationOwnership.userData, .generated)
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(source.environmentText).effectiveValues[
                "CLAUDE_CONFIG_DIR"], paths.claudeConfig.url.path)
        let analysis = await store.launchConfigurationCompiler.analyze(source)
        let prepared = try await store.launchConfigurationCompiler.prepare(
            source,
            override: LaunchDiagnosticOverride(
                requestID: source.requestID,
                configurationFingerprint: analysis.configurationFingerprint
            ))
        XCTAssertEqual(
            prepared.arguments,
            ["unfinished", "--user-data-dir=\(paths.userData.url.path)"])
        XCTAssertEqual(
            prepared.environment["CLAUDE_CONFIG_DIR"], paths.claudeConfig.url.path)
    }

    @MainActor
    func testBlankClaudeUserDataFallsBackToManagedPath() async throws {
        let (store, originalApplication, originalProfile) = try fixture()
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        var application = originalApplication
        application.preset = .claude
        application.appPath = bundle.url.path
        application.bundleIdentifier = bundle.bundleIdentifier
        var profile = originalProfile
        profile.isolationOwnership = .explicit
        profile.argumentsText = "--user-data-dir= --flag -- positional"
        let paths = try store.managedPaths(for: application, profile: profile)
        let source = store.launchConfigurationSource(
            application: application, profile: profile, requestID: UUID())
        let prepared = try await store.launchConfigurationCompiler.prepare(source)
        XCTAssertEqual(
            prepared.arguments,
            [
                "--flag", "--user-data-dir=\(paths.userData.url.path)", "--",
                "positional",
            ])
    }

    @MainActor
    func testRemovingOrRepairingIsolationValuesRestoresGeneratedOwnership() throws {
        let (store, application, original) = try fixture()
        var baseline = original
        baseline.argumentsText = "--user-data-dir=/external"
        baseline.environmentText = "CODEX_HOME=/external"
        baseline.isolationOwnership = .explicit
        let paths = try store.managedPaths(for: application, profile: baseline)
        for (arguments, environment) in [
            ("", ""),
            ("--user-data-dir=", "CODEX_HOME="),
            (
                LaunchArgumentParser.quote(
                    "--user-data-dir=\(paths.userData.url.path)"),
                "CODEX_HOME=\(paths.codexHome.url.path)"
            ),
        ] {
            var draft = baseline
            draft.argumentsText = arguments
            draft.environmentText = environment
            let updated = store.profileApplyingEditedIsolationOwnership(
                draft, baseline: baseline, application: application)
            XCTAssertEqual(updated.isolationOwnership, original.isolationOwnership)
        }
        var generatedBaseline = original
        generatedBaseline.argumentsText = LaunchArgumentParser.quote(
            "--user-data-dir=\(paths.userData.url.path)")
        var typo = generatedBaseline
        typo.argumentsText = "'" + generatedBaseline.argumentsText
        let edited = store.profileApplyingEditedIsolationOwnership(
            typo, baseline: generatedBaseline, application: application)
        XCTAssertEqual(edited.isolationOwnership.userData, .generated)
    }

    @MainActor
    func testIsolationValueSavesWhenManagedRootIsUnavailable() throws {
        let (store, originalApplication, baseline) = try fixture()
        var application = originalApplication
        application.baseStoragePath = "relative/root"
        store.applications = [application]
        let snapshot = try LibraryRepository(applicationSupportURL: root).save(
            [application], expectedVersion: try XCTUnwrap(store.libraryVersionToken)
        )
        store.libraryVersionToken = snapshot.versionToken
        var draft = baseline
        draft.argumentsText = "--user-data-dir=/external"
        draft.environmentText = "CODEX_HOME=/external"
        XCTAssertTrue(
            store.applyProfileEdit(
                draft: draft, baseline: baseline, applicationID: application.id,
                baselineVersion: snapshot.versionToken), store.errorMessage ?? "")
        let saved = try XCTUnwrap(store.applications.first?.profiles.first)
        XCTAssertEqual(saved.argumentsText, draft.argumentsText)
        XCTAssertEqual(saved.environmentText, draft.environmentText)
        XCTAssertEqual(saved.isolationOwnership, .explicit)
    }

    @MainActor
    func testSecretDraftsAndCodexFolderWorkWithUnrelatedInvalidLine() async throws {
        let secrets = CFGAuditSecretStore()
        let (store, _, original) = try fixture(secretStore: secrets)
        var profile = original
        profile.environmentText = "export UNRELATED=fixture"
        let stagedValue = await store.stageKeychainSecret(
            "fixture", environmentKey: "API_KEY", in: profile)
        let staged = try XCTUnwrap(stagedValue)
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(staged.profile.environmentText)
                .effectiveValues["API_KEY"], staged.reference.token)
        let removed = try XCTUnwrap(
            store.profileDraftRemovingKeychainSecret(
                environmentKey: "API_KEY", from: staged.profile))
        XCTAssertEqual(removed.reference, staged.reference)
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(removed.profile.environmentText)
                .effectiveValues["API_KEY"], "")
        let selected = store.profileDraftUsingCodexHome(
            root.appendingPathComponent("Chosen"), profile: profile)
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(selected.environmentText).effectiveValues[
                "CODEX_HOME"], root.appendingPathComponent("Chosen").path)
        XCTAssertEqual(selected.isolationOwnership.codexHome, .explicit)
        XCTAssertTrue(
            selected.environmentText.hasPrefix(profile.environmentText + "\n"))
    }

    @MainActor
    private func assertEditsBlocked(
        store: LibraryStore, application: ManagedApplication, profile: LaunchProfile
    ) throws {
        let version = try XCTUnwrap(store.libraryVersionToken)
        var draft = profile
        draft.notes = "Changed"
        XCTAssertFalse(
            store.applyProfileEdit(
                draft: draft, baseline: profile, applicationID: application.id,
                baselineVersion: version), store.errorMessage ?? "")
        var appDraft = application
        appDraft.displayName = "Changed"
        XCTAssertFalse(
            store.applyApplicationEdit(
                draft: appDraft, baseline: application, baselineVersion: version),
            store.errorMessage ?? "")
        let latest = try XCTUnwrap(store.applications.first)
        let preview = try XCTUnwrap(
            store.presetChangePreview(for: latest, targetPreset: .chrome))
        appDraft.preset = .chrome
        XCTAssertFalse(
            store.applyApplicationPresetEdit(
                draft: appDraft, baseline: application, baselineVersion: version,
                preview: preview, refreshGeneratedValues: false))
        XCTAssertEqual(store.applications, [application])
        XCTAssertEqual(store.libraryVersionToken, version)
        guard
            case .loaded(let snapshot) = LibraryRepository(applicationSupportURL: root)
                .load()
        else {
            return XCTFail("Expected untouched library")
        }
        XCTAssertEqual(snapshot.applications, [application])
    }

    @MainActor
    private func fixture(
        settings: AppSettings? = nil, name: String = "Fixture",
        secretStore: (any SecretStoring)? = nil
    ) throws -> (LibraryStore, ManagedApplication, LaunchProfile) {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profiles"),
            withIntermediateDirectories: true
        )
        let settings = settings ?? AppSettings()
        let profile = LaunchProfile(
            name: name,
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated, codexHome: .generated))
        let application = ManagedApplication(
            displayName: name, bundleIdentifier: "example.fixture",
            appPath: root.appendingPathComponent("Fixture.app").path, preset: .codex,
            baseStoragePath: root.appendingPathComponent("Profiles").path,
            profiles: [profile])
        let snapshot = try LibraryRepository(applicationSupportURL: root).save(
            [application], expectedVersion: .missing)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: root),
            repository: LibraryRepository(applicationSupportURL: root),
            secretStore: secretStore, settings: settings)
        store.applications = snapshot.applications
        store.libraryVersionToken = snapshot.versionToken
        return (store, application, profile)
    }
}

private actor CFGAuditSecretStore: SecretStoring {
    private var values: [EnvironmentSecretReference: SecretValue] = [:]

    func resolve(_ reference: EnvironmentSecretReference) throws -> SecretValue {
        guard let value = values[reference] else {
            throw SecretStoreError.missing(reference)
        }
        return value
    }

    func store(_ value: SecretValue, for reference: EnvironmentSecretReference) {
        values[reference] = value
    }

    func remove(_ reference: EnvironmentSecretReference) {
        values.removeValue(forKey: reference)
    }
}
