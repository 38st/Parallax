import XCTest

@testable import Parallax

final class IntegrationLaunchAuditRegressionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CFG-Isolation-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
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
        XCTAssertEqual(review.environmentEntries.map { $0.risks.map(\.rawValue) }, [
            ["runtime"], ["runtime"], ["networkTrust"], ["networkTrust"], ["networkTrust"], ["sensitive"],
        ])
    }

    func testRequiredClaudeConfigurationCannotBeMissing() async throws {
        let fixture = try ValidApplicationBundleFixture.create(in: root)
        let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(
            source(fixture: fixture, environment: "", requiresClaudeConfigIsolation: true)
        )
        XCTAssertTrue(analysis.diagnostics.contains {
            $0.code == .unresolvedIsolationPath && !$0.isOverridable
        })
    }

    func testRuntimeAndNetworkRisksHaveAccurateLocalizedLabels() throws {
        let cases: [(ImportedLaunchEnvironmentRisk, String, String)] = [
            (.runtime, "Runtime options", "Opciones del entorno de ejecución"),
            (.networkTrust, "Network routing or certificates", "Enrutamiento de red o certificados"),
        ]
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Parallax/Resources")
        for language in ["en", "es"] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let catalog = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for (risk, english, spanish) in cases {
                XCTAssertEqual(catalog[english], language == "en" ? english : spanish)
                XCTAssertTrue([english, spanish].contains(risk.label))
            }
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
