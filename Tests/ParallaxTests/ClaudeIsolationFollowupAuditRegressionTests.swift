import XCTest

@testable import Parallax

final class ClaudeIsolationFollowupAuditRegressionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("W3-Claude-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func fixture(environment: String = "") throws -> (LibraryStore, ManagedApplication, LaunchProfile) {
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let profile = LaunchProfile(name: "First", environmentText: environment)
        let app = ManagedApplication(
            displayName: "Claude", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: root.path,
            profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        return (LibraryStore(repository: repository, settings: AppSettings()), app, profile)
    }

    @MainActor
    func testClaudePeerCollisionUsesExpandedPathAndCannotBeOverridden() async throws {
        let (store, original, profile) = try fixture(environment: "CLAUDE_CONFIG_DIR=~/Shared")
        var app = original
        let shared = root.appendingPathComponent("Shared")
        app.profiles.append(LaunchProfile(name: "Second", environmentText: "CLAUDE_CONFIG_DIR=\(shared.path)"))
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let compiler = LaunchConfigurationCompiler(
            identity: ChildEnvironmentIdentity(
                homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path),
            processEnvironment: [:])
        let analysis = await compiler.analyze(source)
        XCTAssertTrue(analysis.profileHealth?.paths.contains { $0.requestedURL.path == shared.path } == true)
        let collision = analysis.diagnostics.first { $0.code == .profileHealth(.canonicalPathCollision) }
        XCTAssertNotNil(collision)
        XCTAssertEqual(collision?.isOverridable, false)
        do {
            _ = try await compiler.prepare(source)
            XCTFail("A shared Claude configuration must block launch")
        } catch LaunchPreparationError.blocked { }
        do {
            _ = try await compiler.prepare(source, override: LaunchDiagnosticOverride(
                requestID: source.requestID, configurationFingerprint: analysis.configurationFingerprint,
                allowsActiveProfileRisk: true))
            XCTFail("Collision safety must match the existing isolation roles")
        } catch LaunchPreparationError.blocked { }
    }

    @MainActor
    func testCustomPresetDoesNotBlockOnSharedClaudeConfig() async throws {
        let shared = root.appendingPathComponent("Shared").path
        let (store, original, profile) = try fixture(environment: "CLAUDE_CONFIG_DIR=\(shared)")
        var app = original
        app.preset = .custom
        app.profiles.append(LaunchProfile(name: "Second", environmentText: "CLAUDE_CONFIG_DIR=\(shared)"))
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let analysis = await compiler.analyze(source)
        XCTAssertFalse(analysis.diagnostics.contains { $0.severity == .error && !$0.isOverridable })
        _ = try await compiler.prepare(source)
        let reports = LaunchHealthService().inspectProfiles(app.profiles.map {
            store.profileHealthInput(for: app, profile: $0)
        })
        XCTAssertTrue(reports.allSatisfy { $0.issues.isEmpty })
        let review = ImportedLaunchTrust().review(for: store.importedLaunchTrustSource(
            application: app, profile: profile, analysis: analysis, source: source))
        XCTAssertTrue(review.isolationPaths.contains { $0.role == .claudeConfig })
    }

    @MainActor
    func testCustomPresetDoesNotBlockOnUnwritableClaudeConfig() async throws {
        let readOnly = root.appendingPathComponent("ReadOnly")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let (store, original, profile) = try fixture(environment: "CLAUDE_CONFIG_DIR=\(readOnly.path)")
        var app = original
        app.preset = .custom
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let access = ClaudeReviewWriteAccess(unwritablePath: readOnly.path)
        let compiler = LaunchConfigurationCompiler(writeAccess: access, processEnvironment: [:])
        let analysis = await compiler.analyze(source)
        XCTAssertFalse(analysis.diagnostics.contains { $0.severity == .error && !$0.isOverridable })
        _ = try await compiler.prepare(source)
        let reports = LaunchHealthService(writeAccess: access).inspectProfiles([
            store.profileHealthInput(for: app, profile: profile)
        ])
        XCTAssertTrue(reports.allSatisfy { $0.issues.isEmpty })
    }

    @MainActor
    func testEditorHealthIncludesImplicitClaudeConfigAndDetectsExplicitCollision() throws {
        let (store, app, profile) = try fixture()
        let paths = try store.managedPaths(for: app, profile: profile)
        let service = LaunchHealthService()
        let managed = try XCTUnwrap(service.inspectProfiles([
            store.profileHealthInput(for: app, profile: profile)
        ]).first)
        XCTAssertTrue(managed.paths.contains {
            $0.role == .managedClaudeConfig && $0.requestedURL == paths.claudeConfig.url
        })
        let shared = root.appendingPathComponent("Shared")
        let first = LaunchProfile(name: "First", environmentText: "CLAUDE_CONFIG_DIR=\(shared.path)")
        let second = LaunchProfile(name: "Second", environmentText: "CLAUDE_CONFIG_DIR=\(shared.path)")
        let reports = service.inspectProfiles([first, second].map { store.profileHealthInput(for: app, profile: $0) })
        XCTAssertTrue(reports.allSatisfy { $0.issues.contains { $0.code == .canonicalPathCollision } })
    }

    @MainActor
    func testImportedReviewIncludesClaudeConfigurationAuthorityAndCanonicalPath() async throws {
        let shared = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        let (store, app, profile) = try fixture(environment: "CLAUDE_CONFIG_DIR=\(alias.path)")
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let analysis = await compiler.analyze(source)
        let review = ImportedLaunchTrust().review(for: store.importedLaunchTrustSource(
            application: app, profile: profile, analysis: analysis, source: source))
        let config = review.isolationPaths.first { $0.canonicalPath == shared.resolvingSymlinksInPath().path }
        XCTAssertEqual(config?.role.rawValue, "claudeConfig")
        XCTAssertEqual(config?.authority, .external)
    }

    @MainActor
    func testManagedClaudeAnalysisAndReviewMatchPreparedEnvironment() async throws {
        let (store, app, profile) = try fixture()
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let analysis = await compiler.analyze(source)
        let prepared = try await compiler.prepare(source)
        let config = try XCTUnwrap(analysis.isolation.claudeConfig)
        XCTAssertTrue(config.isManaged)
        XCTAssertEqual(config.url.path, prepared.environment["CLAUDE_CONFIG_DIR"])
        let review = ImportedLaunchTrust().review(for: store.importedLaunchTrustSource(
            application: app, profile: profile, analysis: analysis, source: source))
        let reviewed = try XCTUnwrap(review.isolationPaths.first { $0.role == .claudeConfig })
        XCTAssertEqual(reviewed.authority, .managed)
        XCTAssertEqual(reviewed.canonicalPath, config.canonicalURL.path)
    }

    @MainActor
    func testClaudeDuplicateDropsAllExplicitConfigEntriesAndKeepsOtherText() throws {
        let text = "# note\r\nCLAUDE_CONFIG_DIR=/first\r\nKEEP=one\u{2028}two\r\nCLAUDE_CONFIG_DIR=/last\n"
        let (store, app, profile) = try fixture(environment: text)
        let duplicate = try store.applyingRecommendedSettings(
            to: profile.duplicatedWithFreshIdentity(), for: app, replacingExistingIsolation: true)
        XCTAssertNil(LaunchEnvironmentParser.parse(duplicate.environmentText).effectiveValues["CLAUDE_CONFIG_DIR"])
        XCTAssertTrue(duplicate.environmentText.contains("KEEP=one\u{2028}two\r\n"))
        XCTAssertTrue(duplicate.environmentText.hasPrefix("# note\r\n"))
        let source = store.launchConfigurationSource(application: app, profile: duplicate, requestID: UUID())
        let paths = try store.managedPaths(for: app, profile: duplicate)
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(source.environmentText).effectiveValues["CLAUDE_CONFIG_DIR"],
            paths.claudeConfig.url.path)
        XCTAssertNotEqual(duplicate.storageID, profile.storageID)
        var custom = app
        custom.preset = .custom
        let customCopy = try store.applyingRecommendedSettings(
            to: profile.duplicatedWithFreshIdentity(), for: custom, replacingExistingIsolation: true)
        XCTAssertEqual(customCopy.environmentText, text)
        XCTAssertEqual(try store.applyingRecommendedSettings(to: profile, for: app).environmentText, text)
    }
}
