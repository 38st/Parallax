import XCTest

@testable import Parallax

final class EditorCompositionFollowupAuditRegressionTests: XCTestCase {
    func testSensitivityOptionsClassifyCredentialBearingLiteralValues() throws {
        let text = "REDIS_URL=redis://user:synthetic-password@fixture\nPUBLIC_URL=https://fixture\nTOKEN=synthetic"
        let options = ProfileEditorSecurityPresentation.environmentSensitivityOptions(for: text)
        XCTAssertEqual(options.first { $0.key == "REDIS_URL" }?.isAutomaticallySensitive, true)
        XCTAssertEqual(options.first { $0.key == "PUBLIC_URL" }?.isAutomaticallySensitive, false)
        XCTAssertEqual(options.first { $0.key == "TOKEN" }?.isAutomaticallySensitive, true)
    }

    @MainActor
    func testOutOfRangeDiscoveryErrorFailsClosedWithoutTrapping() {
        let composition = ParallaxAppComposition(builders: .init(
            discoverApplicationSupport: { throw NSError(domain: "Synthetic", code: Int.max) },
            bootstrapSettings: { _ in fatalError("Discovery failed") },
            makeSharedServices: { container, error, failure in
                XCTAssertEqual(failure, .systemCall(operation: "locate Application Support", code: EIO))
                return ParallaxSharedServices(
                    trustedContainer: container, applicationSupportInitializationError: error,
                    containerBootstrapFailure: failure,
                    corporateUsageStore: CorporateUsageStore(initialAccounts: []))
            },
            makeLibraryStoreFactory: {
                ParallaxLibraryStoreFactory(sharedServices: $0, settings: $1, libraryChanges: $2)
            }))
        XCTAssertEqual(composition.settings.persistenceAuthority, .recoveryOnly)
    }
}
