import XCTest

@testable import Parallax

final class ClaudeIsolationReviewAuditRegressionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("W3-Claude-Review-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func fixture(
        profiles: [LaunchProfile], fileSystem: any FileSystem = LocalFileSystem()
    ) throws -> (LibraryStore, ManagedApplication) {
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let app = ManagedApplication(
            displayName: "Claude", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: root.path,
            profiles: profiles)
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        return (LibraryStore(repository: repository, fileSystem: fileSystem, settings: AppSettings()), app)
    }

    @MainActor
    func testClaudeHealthChecklistIdentifiesManagedAndExternalConfigFailures() throws {
        for isManaged in [true, false] {
            let config = root.appendingPathComponent("External")
            let profile = LaunchProfile(
                name: "Work", environmentText: isManaged ? "" : "CLAUDE_CONFIG_DIR=\(config.path)")
            let (store, app) = try fixture(profiles: [profile])
            let paths = try store.managedPaths(for: app, profile: profile)
            let target = isManaged ? paths.claudeConfig.url : config
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let source = store.healthInspectionSource(for: app, profile: profile)
            let healthy = LibraryStore.inspectHealth(source, service: LaunchHealthService())
            let label = String(localized: "Claude configuration folder")
            XCTAssertEqual(healthy.first { $0.label == label }?.isHealthy, true)
            let unhealthy = LibraryStore.inspectHealth(source, service: LaunchHealthService(
                writeAccess: ClaudeReviewWriteAccess(unwritablePath: target.path)))
            XCTAssertEqual(unhealthy.first { $0.label == label }?.isHealthy, false)
            try FileManager.default.removeItem(at: root.appendingPathComponent("Support"))
        }
    }

    @MainActor
    func testClaudeCollisionDiagnosticNamesPeerAndExplainsManagedPathRecovery() async throws {
        let config = root.appendingPathComponent("Shared")
        let profiles = ["First", "Second"].map {
            LaunchProfile(name: $0, environmentText: "CLAUDE_CONFIG_DIR=\(config.path)")
        }
        let (store, app) = try fixture(profiles: profiles)
        let profile = try XCTUnwrap(profiles.first)
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
        let collision = try XCTUnwrap(analysis.diagnostics.first {
            $0.code == .profileHealth(.canonicalPathCollision)
        })
        XCTAssertFalse(collision.isOverridable)
        XCTAssertTrue(collision.message.contains("Second"), collision.message)
        XCTAssertTrue(collision.message.contains(
            "Remove the explicit CLAUDE_CONFIG_DIR entry from one of these spaces"), collision.message)
        XCTAssertTrue(collision.message.contains("its own managed folder"), collision.message)
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Parallax/Resources")
        let spanishBundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("es.lproj")))
        let spanish = LaunchCompilerDiagnostic.claudeConfigCollisionMessage(
            profileNames: collision.claudeConfigCollisionProfileNames,
            bundle: spanishBundle, locale: Locale(identifier: "es"))
        XCTAssertEqual(spanish,
            "La carpeta de configuración de Claude también se utiliza en: Second. "
                + "Elimine la entrada explícita CLAUDE_CONFIG_DIR de uno de estos espacios "
                + "para que utilice su propia carpeta administrada.")
        XCTAssertEqual(String(localized: "Claude configuration folder", bundle: spanishBundle),
            "Carpeta de configuración de Claude")
        let items = LibraryStore.inspectHealth(
            store.healthInspectionSource(for: app, profile: profile), service: LaunchHealthService())
        XCTAssertEqual(items.first {
            $0.label == String(localized: "Claude configuration folder")
        }?.isHealthy, false)
    }

    @MainActor
    func testHealthInputConstructionDoesNotResolveFilesystemPaths() throws {
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        let profiles = [
            LaunchProfile(name: "Managed"),
            LaunchProfile(name: "Explicit", environmentText: "CLAUDE_CONFIG_DIR=\(root.path)/External"),
        ]
        let (store, app) = try fixture(profiles: profiles, fileSystem: fileSystem)
        let priorReads = fileSystem.events.count
        for profile in profiles {
            _ = store.profileHealthInput(for: app, profile: profile)
        }
        XCTAssertEqual(fileSystem.events.count, priorReads)
    }

    @MainActor
    func testTwoImplicitClaudeSpacesHaveDistinctHealthyPathsAtLaunchAndInEditor() async throws {
        let profiles = [LaunchProfile(name: "First"), LaunchProfile(name: "Second")]
        let (store, app) = try fixture(profiles: profiles)
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        var paths: Set<String> = []
        for profile in profiles {
            let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
            let analysis = await compiler.analyze(source)
            XCTAssertFalse(analysis.hasBlockingDiagnostics)
            let path = try XCTUnwrap(analysis.isolation.claudeConfig)
            XCTAssertTrue(path.isManaged)
            paths.insert(path.url.path)
            _ = try await compiler.prepare(source)
        }
        XCTAssertEqual(paths.count, 2)
        let reports = LaunchHealthService().inspectProfiles(profiles.map {
            store.profileHealthInput(for: app, profile: $0)
        })
        XCTAssertTrue(reports.allSatisfy { $0.isHealthy })
        XCTAssertEqual(Set(reports.flatMap { report in
            report.paths.filter { $0.role == .managedClaudeConfig }.map { $0.requestedURL.path }
        }), paths)
    }

    @MainActor
    func testTildeManagedClaudePathIsPreparedAndMatchesCompiledEnvironment() async throws {
        var profile = LaunchProfile(name: "Work")
        let (store, app) = try fixture(profiles: [profile])
        let paths = try store.managedPaths(for: app, profile: profile)
        let managed = paths.claudeConfig.url
        let home = root.path
        XCTAssertTrue(managed.path.hasPrefix(home + "/"))
        profile.environmentText = "CLAUDE_CONFIG_DIR=~\(managed.path.dropFirst(home.count))"
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        let compiler = LaunchConfigurationCompiler(
            identity: ChildEnvironmentIdentity(
                homeDirectory: home, userName: "fixture", temporaryDirectory: root.path),
            processEnvironment: [:])
        let analysis = await compiler.analyze(source)
        XCTAssertTrue(analysis.isolation.claudeConfig?.isManaged == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        let prepared = try await compiler.prepare(source)
        XCTAssertEqual(prepared.environment["CLAUDE_CONFIG_DIR"], managed.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
        if FileManager.default.fileExists(atPath: managed.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: managed.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }
}

struct ClaudeReviewWriteAccess: PathWriteAccessChecking {
    let unwritablePath: String

    func isWritable(at url: URL) -> Bool {
        url.standardizedFileURL.path != URL(fileURLWithPath: unwritablePath).resolvingSymlinksInPath().path
    }
}
