import XCTest

@testable import Parallax

final class LaunchIsolationAuditRegressionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CFG-Isolation-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testManagedClaudeConfigIsPreparedWithExternalUserData() async throws {
        let fixture = try ValidApplicationBundleFixture.create(in: root)
        let applicationStorageID = UUID()
        let profileStorageID = UUID()
        let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
            configuredBaseRoot: root.path, applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID)
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(
            at: external, withIntermediateDirectories: true)
        let source = source(
            fixture: fixture, applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID,
            arguments: LaunchArgumentParser.quote("--user-data-dir=\(external.path)"),
            environment: "CLAUDE_CONFIG_DIR=\(paths.claudeConfig.url.path)")
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        _ = try await compiler.prepare(source)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.claudeConfig.url.path))
        guard FileManager.default.fileExists(atPath: paths.claudeConfig.url.path) else {
            return
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.claudeConfig.url.path)
        _ = try await compiler.prepare(source)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.claudeConfig.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testClaudeConfigRejectsRelativeAndSecretPaths() async throws {
        let fixture = try ValidApplicationBundleFixture.create(in: root)
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let relative = await compiler.analyze(
            source(
                fixture: fixture, environment: "CLAUDE_CONFIG_DIR=relative/path",
                requiresClaudeConfigIsolation: true))
        XCTAssertTrue(
            relative.diagnostics.contains {
                $0.code == .profileHealth(.externalPathInvalid) && !$0.isOverridable
            })
        let secret = await compiler.analyze(
            source(
                fixture: fixture,
                environment: "CLAUDE_CONFIG_DIR=\(EnvironmentSecretReference().token)",
                requiresClaudeConfigIsolation: true))
        XCTAssertTrue(
            secret.diagnostics.contains {
                $0.code == .unresolvedIsolationPath && !$0.isOverridable
            })
    }

    func testNonClaudeConfigurationDoesNotBlockOnClaudePaths() async throws {
        let fixture = try ValidApplicationBundleFixture.create(in: root)
        let readOnly = root.appendingPathComponent("ReadOnly")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let compiler = LaunchConfigurationCompiler(
            writeAccess: ClaudeReviewWriteAccess(unwritablePath: readOnly.path), processEnvironment: [:])
        for value in ["", "relative/path", root.appendingPathComponent("Missing").path, readOnly.path] {
            let analysis = await compiler.analyze(
                source(
                    fixture: fixture, environment: "CLAUDE_CONFIG_DIR=\(value)"
                ))
            XCTAssertFalse(
                analysis.diagnostics.contains {
                    $0.severity == .error && !$0.isOverridable
                })
        }
    }

    func testClaudeIsolationRequirementIsBoundToLaunchApproval() throws {
        let fixture = try ValidApplicationBundleFixture.create(in: root)
        var configured = source(
            fixture: fixture, environment: "CLAUDE_CONFIG_DIR=relative")
        let original = LaunchConfigurationCompiler.configurationFingerprint(
            for: configured)
        configured.requiresClaudeConfigIsolation = true
        XCTAssertNotEqual(
            original,
            LaunchConfigurationCompiler.configurationFingerprint(for: configured))
    }

    func testNodeRuntimeOptionsAreFlaggedDuringImportReview() {
        let review = ImportedLaunchTrust().review(
            for: ImportedLaunchTrustSource(
                applicationID: UUID(), applicationStorageID: UUID(),
                applicationDisplayName: "Fixture",
                canonicalApplicationURL: root.appendingPathComponent("Fixture.app"),
                expectedBundleIdentifier: "example.fixture",
                verifiedBundleIdentifier: "example.fixture",
                profileID: UUID(), profileStorageID: UUID(), profileName: "Fixture",
                configuredBaseRoot: root.path,
                argumentsText: "",
                environmentText:
                    """
                    NODE_OPTIONS=--require=/fixture
                    ELECTRON_RUN_AS_NODE=1
                    NODE_EXTRA_CA_CERTS=/fixture
                    HTTPS_PROXY=http://proxy
                    ALL_PROXY=socks5://proxy
                    REDIS_URL=redis://u:p@host
                    """,
                isolationOwnership: .explicit, childEnvironmentPolicy: .safeDefault,
                sensitiveEnvironmentKeys: [], isolationPaths: []
            ))
        XCTAssertEqual(
            review.dangerousEnvironmentKeys,
            [
                "NODE_OPTIONS", "ELECTRON_RUN_AS_NODE", "NODE_EXTRA_CA_CERTS",
                "HTTPS_PROXY", "ALL_PROXY", "REDIS_URL",
            ])
    }

    func testKeychainErrorsUseCompleteLocalizedMessages() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Parallax/Resources")
        let cases: [(SecretStoreError.Operation, String, String)] = [
            (
                .read, "Reading from Keychain failed with status %d.",
                "No se pudo leer del Llavero. Código de estado: %d."
            ),
            (
                .write, "Writing to Keychain failed with status %d.",
                "No se pudo escribir en el Llavero. Código de estado: %d."
            ),
            (
                .update, "Updating Keychain failed with status %d.",
                "No se pudo actualizar el Llavero. Código de estado: %d."
            ),
            (
                .delete, "Deleting from Keychain failed with status %d.",
                "No se pudo eliminar del Llavero. Código de estado: %d."
            ),
        ]
        var expectedByOperation: [SecretStoreError.Operation: Set<String>] = [:]
        for language in ["en", "es"] {
            let data = try Data(
                contentsOf: resources.appendingPathComponent(
                    "\(language).lproj/Localizable.strings"))
            let catalog = try XCTUnwrap(
                try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: String])
            for (operation, key, spanish) in cases {
                let format = try XCTUnwrap(catalog[key])
                XCTAssertEqual(format, language == "en" ? key : spanish)
                expectedByOperation[operation, default: []].insert(
                    String(format: format, Int32(-1)))
            }
            XCTAssertNil(catalog["Keychain %@ failed with status %d."])
        }
        for (operation, _, _) in cases {
            let actual = try XCTUnwrap(
                SecretStoreError.keychainFailure(operation: operation, status: -1)
                    .errorDescription)
            XCTAssertTrue(
                expectedByOperation[operation]?.contains(actual) == true, actual)
        }
    }

    private func source(
        fixture: ValidApplicationBundleFixture, applicationStorageID: UUID = UUID(),
        profileStorageID: UUID = UUID(), arguments: String = "", environment: String,
        requiresClaudeConfigIsolation: Bool = false
    ) -> LaunchConfigurationSource {
        LaunchConfigurationSource(
            requestID: UUID(), applicationID: UUID(),
            applicationStorageID: applicationStorageID, profileID: UUID(),
            profileStorageID: profileStorageID, configurationRevision: 0,
            applicationURL: fixture.url,
            expectedBundleIdentifier: fixture.bundleIdentifier,
            configuredBaseRoot: root.path, argumentsText: arguments,
            environmentText: environment, isolationOwnership: .explicit,
            childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [],
            requiresClaudeConfigIsolation: requiresClaudeConfigIsolation)
    }
}
