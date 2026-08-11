import Foundation
import XCTest
@testable import Parallax

final class SensitiveConfigurationTextSanitizerTests: XCTestCase {
    private let sanitizer = SensitiveConfigurationTextSanitizer()

    func testEnvironmentGoldenOutputsPreserveReferencesAndUTF16Ranges()
        throws
    {
        let reference = EnvironmentSecretReference(
            id: UUID(
                uuidString:
                    "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!
        )
        let source = """
            DISPLAY=🙂
            OPENAI_API_KEY=秘密🔐
            OPENAI_API_KEY=second
            NPM_TOKEN=\(reference.token)
            """

        let omitted = try sanitizer.sanitizeEnvironment(
            source,
            explicitSensitiveKeys: [],
            policy: .omit
        )
        let redacted = try sanitizer.sanitizeEnvironment(
            source,
            explicitSensitiveKeys: [],
            policy: .redact
        )
        let included = try sanitizer.sanitizeEnvironment(
            source,
            explicitSensitiveKeys: [],
            policy: .includeAfterExplicitConfirmation
        )

        XCTAssertEqual(
            omitted.text,
            """
            DISPLAY=🙂
            # Omitted sensitive value: OPENAI_API_KEY
            # Omitted sensitive value: OPENAI_API_KEY
            NPM_TOKEN=\(reference.token)
            """
        )
        XCTAssertEqual(
            redacted.text,
            """
            DISPLAY=🙂
            OPENAI_API_KEY=<redacted>
            OPENAI_API_KEY=<redacted>
            NPM_TOKEN=\(reference.token)
            """
        )
        XCTAssertEqual(included.text, source)
        XCTAssertTrue(omitted.containsSensitiveContent)
        XCTAssertTrue(redacted.containsSensitiveContent)
        XCTAssertTrue(included.containsSensitiveContent)
        XCTAssertTrue(omitted.wasModified)
        XCTAssertTrue(redacted.wasModified)
        XCTAssertFalse(included.wasModified)
    }

    func testEnvironmentRejectsMalformedTextBeforeApplyingEveryPolicy() {
        let malformed = "OPENAI_API_KEY=secret\u{0000}suffix"
        let policies: [SensitiveConfigurationTextSanitizationPolicy] = [
            .omit,
            .redact,
            .includeAfterExplicitConfirmation,
        ]

        for policy in policies {
            XCTAssertThrowsError(
                try sanitizer.sanitizeEnvironment(
                    malformed,
                    explicitSensitiveKeys: [],
                    policy: policy
                )
            ) { error in
                XCTAssertEqual(
                    error as? SensitiveConfigurationTextSanitizationError,
                    .invalidEnvironment
                )
            }
        }
    }

    func testReferenceOnlySensitiveEnvironmentIsUnchangedForEveryPolicy()
        throws
    {
        let reference = EnvironmentSecretReference(
            id: UUID(
                uuidString:
                    "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            )!
        )
        let source = "OPENAI_API_KEY=\(reference.token)"
        let policies: [SensitiveConfigurationTextSanitizationPolicy] = [
            .omit,
            .redact,
            .includeAfterExplicitConfirmation,
        ]

        for policy in policies {
            let result = try sanitizer.sanitizeEnvironment(
                source,
                explicitSensitiveKeys: [],
                policy: policy
            )

            XCTAssertEqual(result.text, source)
            XCTAssertFalse(result.containsSensitiveContent)
            XCTAssertFalse(result.wasModified)
        }
    }

    func testExplicitSensitiveKeysSanitizeLiteralAndPreserveReference()
        throws
    {
        let reference = EnvironmentSecretReference(
            id: UUID(
                uuidString:
                    "cccccccc-cccc-cccc-cccc-cccccccccccc"
            )!
        )
        let source = """
            INTERNAL_VALUE=private
            INTERNAL_REFERENCE=\(reference.token)
            """
        let result = try sanitizer.sanitizeEnvironment(
            source,
            explicitSensitiveKeys: [
                "INTERNAL_VALUE",
                "INTERNAL_REFERENCE",
            ],
            policy: .redact
        )

        XCTAssertEqual(
            result.text,
            """
            INTERNAL_VALUE=<redacted>
            INTERNAL_REFERENCE=\(reference.token)
            """
        )
        XCTAssertTrue(result.containsSensitiveContent)
        XCTAssertTrue(result.wasModified)
    }

    func testArgumentGoldenOutputsPreserveExistingPolicyBehavior() throws {
        let source =
            "--api-key=秘密🔐 --password 'two words' --password-store=basic visible"

        let omitted = try sanitizer.sanitizeArguments(
            source,
            policy: .omit
        )
        let redacted = try sanitizer.sanitizeArguments(
            source,
            policy: .redact
        )
        let included = try sanitizer.sanitizeArguments(
            source,
            policy: .includeAfterExplicitConfirmation
        )

        XCTAssertEqual(
            omitted.text,
            "--password --password-store=basic visible"
        )
        XCTAssertEqual(
            redacted.text,
            "'<redacted>' --password '<redacted>' --password-store=basic visible"
        )
        XCTAssertEqual(included.text, source)
        XCTAssertTrue(omitted.containsSensitiveContent)
        XCTAssertTrue(redacted.containsSensitiveContent)
        XCTAssertTrue(included.containsSensitiveContent)
        XCTAssertTrue(omitted.wasModified)
        XCTAssertTrue(redacted.wasModified)
        XCTAssertFalse(included.wasModified)
    }

    func testArgumentsRejectMalformedTextBeforeApplyingEveryPolicy() {
        let malformed = "--api-key='unterminated"
        let policies: [SensitiveConfigurationTextSanitizationPolicy] = [
            .omit,
            .redact,
            .includeAfterExplicitConfirmation,
        ]

        for policy in policies {
            XCTAssertThrowsError(
                try sanitizer.sanitizeArguments(
                    malformed,
                    policy: policy
                )
            ) { error in
                XCTAssertEqual(
                    error as? SensitiveConfigurationTextSanitizationError,
                    .invalidArguments
                )
            }
        }
    }

    func testPortableAdapterPreservesOwnerSpecificArgumentFailure() {
        let profile = LaunchProfile(
            name: "Profile",
            argumentsText: "--api-key='unterminated"
        )
        let library = LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: "Fixture",
                    appPath: "/Applications/Fixture.app",
                    profiles: [profile]
                )
            ]
        )

        XCTAssertThrowsError(
            try PortableConfigurationService()
                .makeLibraryMetadataExport(
                    library: library,
                    sensitiveLiteralPolicy: .redact
                )
        ) { error in
            XCTAssertEqual(
                error as? PortableConfigurationError,
                .invalidArguments(owner: "Fixture / Profile")
            )
        }
    }

    @MainActor
    func testPortableAndStoreAdaptersMatchSanitizerGoldenOutput() throws {
        let profile = LaunchProfile(
            name: "Profile",
            argumentsText: "--api-key=private --safe=value",
            environmentText:
                "DISPLAY=🙂\nOPENAI_API_KEY=秘密🔐\nOPENAI_API_KEY=second"
        )
        let application = ManagedApplication(
            displayName: "Fixture",
            appPath: "/Applications/Fixture.app",
            profiles: [profile]
        )
        let library = LibraryDocument(applications: [application])
        let portable = PortableConfigurationService()

        for fixture in policyFixtures {
            let expectedEnvironment = try sanitizer.sanitizeEnvironment(
                profile.environmentText,
                explicitSensitiveKeys:
                    Set(profile.sensitiveEnvironmentKeys),
                policy: fixture.sanitizerPolicy
            ).text
            let expectedArguments = try sanitizer.sanitizeArguments(
                profile.argumentsText,
                policy: fixture.sanitizerPolicy
            ).text
            let artifact = try portable.makeLibraryMetadataExport(
                library: library,
                sensitiveLiteralPolicy: fixture.portablePolicy
            )
            let portableProfile = try XCTUnwrap(
                artifact.library.applications.first?.profiles.first
            )

            XCTAssertEqual(
                portableProfile.environmentText,
                expectedEnvironment
            )
            XCTAssertEqual(
                portableProfile.argumentsText,
                expectedArguments
            )
            XCTAssertEqual(
                LibraryStore.exportEnvironmentText(
                    profile,
                    sensitivePolicy: fixture.storePolicy
                ),
                expectedEnvironment
            )
            XCTAssertEqual(
                artifact.header.warnings.map(\.rawValue),
                artifact.header.warnings.map(\.rawValue).sorted()
            )
            XCTAssertEqual(
                artifact.header.disclosure.includedContent.map(\.rawValue),
                artifact.header.disclosure.includedContent
                    .map(\.rawValue).sorted()
            )
            XCTAssertEqual(
                artifact.header.disclosure.excludedContent.map(\.rawValue),
                artifact.header.disclosure.excludedContent
                    .map(\.rawValue).sorted()
            )
        }
    }

    @MainActor
    func testStoreCompatibilityAdaptersFailClosedForMalformedEnvironment() {
        let profile = LaunchProfile(
            name: "Malformed",
            environmentText: "OPENAI_API_KEY=secret\u{0000}suffix"
        )

        XCTAssertTrue(
            LibraryStore.environmentContainsSensitiveLiterals(
                profile.environmentText,
                explicitSensitiveKeys: []
            )
        )
        XCTAssertEqual(
            LibraryStore.exportEnvironmentText(
                profile,
                sensitivePolicy: .omit
            ),
            ""
        )
        XCTAssertEqual(
            LibraryStore.exportEnvironmentText(
                profile,
                sensitivePolicy: .redact
            ),
            ""
        )
        XCTAssertEqual(
            LibraryStore.exportEnvironmentText(
                profile,
                sensitivePolicy: .include
            ),
            ""
        )
    }

    private var policyFixtures: [PolicyFixture] {
        [
            PolicyFixture(
                sanitizerPolicy: .omit,
                portablePolicy: .omit,
                storePolicy: .omit
            ),
            PolicyFixture(
                sanitizerPolicy: .redact,
                portablePolicy: .redact,
                storePolicy: .redact
            ),
            PolicyFixture(
                sanitizerPolicy: .includeAfterExplicitConfirmation,
                portablePolicy: .includeAfterExplicitConfirmation,
                storePolicy: .include
            ),
        ]
    }
}

private struct PolicyFixture {
    let sanitizerPolicy: SensitiveConfigurationTextSanitizationPolicy
    let portablePolicy: SensitiveLiteralExportPolicy
    let storePolicy: LibraryExportSensitivePolicy
}
