import Foundation
import XCTest
@testable import Parallax

final class LaunchSecurityCoreTests: XCTestCase {
    func testSafePolicyExcludesParentSecretsAndProfileAffectingValues() {
        let identity = ChildEnvironmentIdentity(
            homeDirectory: "/Users/fixture",
            userName: "fixture",
            temporaryDirectory: "/private/tmp/fixture"
        )
        let parent = [
            "OPENAI_API_KEY": "parent-secret",
            "CLAUDE_CONFIG_DIR": "/tmp/hidden-claude-config",
            "CODEX_HOME": "/tmp/hidden-codex-home",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
            "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            "UNRELATED_SECRET": "do-not-forward",
            "LANG": "en_US.UTF-8",
        ]

        let environment = ChildEnvironmentPolicy.safeDefault.baseEnvironment(
            processEnvironment: parent,
            identity: identity
        )

        XCTAssertEqual(environment["HOME"], identity.homeDirectory)
        XCTAssertEqual(environment["USER"], identity.userName)
        XCTAssertEqual(environment["LOGNAME"], identity.userName)
        XCTAssertEqual(environment["TMPDIR"], identity.temporaryDirectory)
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(environment["CODEX_HOME"])
        XCTAssertNil(environment["SSH_AUTH_SOCK"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["UNRELATED_SECRET"])
    }

    func testAdvancedInheritanceRequiresExplicitPolicy() {
        let identity = ChildEnvironmentIdentity(
            homeDirectory: "/Users/fixture",
            userName: "fixture",
            temporaryDirectory: "/private/tmp/fixture"
        )
        let parent = ["CUSTOM_BUILD_SETTING": "enabled"]

        XCTAssertNil(
            ChildEnvironmentPolicy.safeDefault.baseEnvironment(
                processEnvironment: parent,
                identity: identity
            )["CUSTOM_BUILD_SETTING"]
        )
        XCTAssertEqual(
            ChildEnvironmentPolicy.inheritProcessEnvironment.baseEnvironment(
                processEnvironment: parent,
                identity: identity
            )["CUSTOM_BUILD_SETTING"],
            "enabled"
        )
    }

    func testAdvancedInheritanceCannotHideIsolationOrLoaderValues()
        async throws
    {
        let identity = ChildEnvironmentIdentity(
            homeDirectory: "/Users/fixture",
            userName: "fixture",
            temporaryDirectory: "/private/tmp/fixture"
        )
        let process = [
            "CUSTOM_BUILD_SETTING": "enabled",
            "CLAUDE_CONFIG_DIR": "/hidden/claude",
            "CODEX_HOME": "/hidden/codex",
            "DYLD_INSERT_LIBRARIES": "/hidden/injection.dylib",
        ]
        let base = ChildEnvironmentPolicy.inheritProcessEnvironment
            .baseEnvironment(
                processEnvironment: process,
                identity: identity
            )

        XCTAssertEqual(base["CUSTOM_BUILD_SETTING"], "enabled")
        XCTAssertNil(base["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(base["CODEX_HOME"])
        XCTAssertNil(base["DYLD_INSERT_LIBRARIES"])

        let prepared = try await LaunchEnvironmentPreparer(
            policy: .inheritProcessEnvironment,
            identity: identity,
            processEnvironment: process,
            secretResolver: MissingSecretResolver()
        ).prepare([
            StoredEnvironmentAssignment(
                key: "CODEX_HOME",
                value: .literal("/explicit/codex")
            ),
        ])
        XCTAssertEqual(prepared["CODEX_HOME"], "/explicit/codex")
        XCTAssertNil(prepared["DYLD_INSERT_LIBRARIES"])
    }

    func testTildeExpansionIsRestrictedToDocumentedPathFields() {
        let expander = PathSpecificTildeExpander(
            homeDirectory: "/Users/fixture"
        )

        XCTAssertEqual(
            expander.environmentValue(
                "~/Claude",
                forKey: "CLAUDE_CONFIG_DIR"
            ),
            "/Users/fixture/Claude"
        )
        XCTAssertEqual(
            expander.environmentValue("~/Codex", forKey: "CODEX_HOME"),
            "/Users/fixture/Codex"
        )
        XCTAssertEqual(
            expander.environmentValue("~/literal", forKey: "LABEL"),
            "~/literal"
        )
        XCTAssertEqual(
            expander.argumentValue("~/Browser", forOption: "--user-data-dir"),
            "/Users/fixture/Browser"
        )
        XCTAssertEqual(
            expander.argumentValue("~/literal", forOption: "--label"),
            "~/literal"
        )
        XCTAssertEqual(
            expander.environmentValue("~another/secret", forKey: "CODEX_HOME"),
            "~another/secret"
        )
    }

    func testSensitiveKeyClassifierIsConservativeWithoutMatchingOrdinaryKeys() {
        let classifier = SensitiveEnvironmentKeyClassifier()

        XCTAssertTrue(classifier.isSensitive("OPENAI_API_KEY"))
        XCTAssertTrue(classifier.isSensitive("github_token"))
        XCTAssertTrue(classifier.isSensitive("DATABASE_PASSWORD"))
        XCTAssertTrue(classifier.isSensitive("CLIENT_SECRET"))
        XCTAssertFalse(classifier.isSensitive("MONKEY"))
        XCTAssertFalse(classifier.isSensitive("KEYBOARD_LAYOUT"))
        XCTAssertFalse(classifier.isSensitive("PUBLIC_KEY"))
        XCTAssertFalse(classifier.isSensitive("PATH"))
    }

    func testExplicitSensitiveKeyMarkingOverridesHeuristics() {
        let policy = EnvironmentDisclosurePolicy(
            explicitSensitiveKeys: ["INTERNAL_ACCOUNT"]
        )
        let assignment = StoredEnvironmentAssignment(
            key: "INTERNAL_ACCOUNT",
            value: .literal("private-value")
        )

        XCTAssertEqual(
            policy.preview([assignment]).first?.displayValue,
            .redacted
        )
        XCTAssertTrue(
            policy.export(
                [assignment],
                sensitiveLiteralPolicy: .omit
            ).isEmpty
        )
    }

    func testSecretValueStringRepresentationsAreAlwaysRedacted() {
        let value = SecretValue("actual-secret")

        XCTAssertEqual(value.description, "<redacted>")
        XCTAssertEqual(value.debugDescription, "<redacted>")
        XCTAssertFalse(String(describing: value).contains("actual-secret"))
        XCTAssertFalse(String(reflecting: value).contains("actual-secret"))
    }

    func testSecretReferenceTokenStrictlyRoundTrips() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        )
        let reference = EnvironmentSecretReference(id: id)

        XCTAssertEqual(
            reference.token,
            "{{keychain:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa}}"
        )
        XCTAssertEqual(
            EnvironmentSecretReference(token: reference.token),
            reference
        )
        XCTAssertNil(EnvironmentSecretReference(token: "{{keychain:not-a-uuid}}"))
        XCTAssertNil(EnvironmentSecretReference(token: "prefix \(reference.token)"))
        XCTAssertNil(EnvironmentSecretReference(token: reference.token + " suffix"))
    }

    func testPreviewAndExportNeverResolveAKeychainReference() async throws {
        let reference = EnvironmentSecretReference()
        let resolver = RecordingSecretResolver(
            values: [reference: SecretValue("resolved-secret")]
        )
        let assignment = StoredEnvironmentAssignment(
            key: "OPENAI_API_KEY",
            value: .secretReference(reference)
        )
        let policy = EnvironmentDisclosurePolicy()

        let preview = policy.preview([assignment])
        let exported = policy.export(
            [assignment],
            sensitiveLiteralPolicy: .includeAfterExplicitConfirmation
        )
        let data = try JSONEncoder().encode(exported)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(preview.first?.displayValue, .redacted)
        XCTAssertEqual(exported.first?.value, reference.token)
        XCTAssertFalse(encoded.contains("resolved-secret"))
        let resolveCallCount = await resolver.resolveCallCount
        XCTAssertEqual(resolveCallCount, 0)
    }

    func testSensitiveLiteralIsRedactedAndOmittedByDefault() throws {
        let assignment = StoredEnvironmentAssignment(
            key: "OPENAI_API_KEY",
            value: .literal("literal-secret")
        )
        let policy = EnvironmentDisclosurePolicy()

        XCTAssertEqual(policy.preview([assignment]).first?.displayValue, .redacted)
        XCTAssertTrue(
            policy.export(
                [assignment],
                sensitiveLiteralPolicy: .omit
            ).isEmpty
        )

        let redacted = policy.export(
            [assignment],
            sensitiveLiteralPolicy: .redact
        )
        let data = try JSONEncoder().encode(redacted)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("literal-secret"))
        XCTAssertTrue(encoded.contains("redacted"))
    }

    func testSecretReferenceEncodingContainsNoResolvedValue() throws {
        let id = try XCTUnwrap(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        )
        let reference = EnvironmentSecretReference(id: id)
        let assignment = StoredEnvironmentAssignment(
            key: "SERVICE_TOKEN",
            value: .secretReference(reference)
        )

        let data = try JSONEncoder().encode(assignment)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(encoded.contains(reference.id.uuidString.lowercased()))
        XCTAssertFalse(encoded.contains("actual-secret"))
    }

    func testMissingSecretFailsWithoutLeakingAnySecretValue() async {
        let reference = EnvironmentSecretReference()
        let preparer = LaunchEnvironmentPreparer(
            policy: .safeDefault,
            identity: ChildEnvironmentIdentity(
                homeDirectory: "/Users/fixture",
                userName: "fixture",
                temporaryDirectory: "/private/tmp/fixture"
            ),
            processEnvironment: [:],
            secretResolver: MissingSecretResolver()
        )

        do {
            _ = try await preparer.prepare([
                StoredEnvironmentAssignment(
                    key: "SERVICE_TOKEN",
                    value: .secretReference(reference)
                ),
            ])
            XCTFail("Expected missing secret resolution to fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("actual-secret"))
            XCTAssertTrue(error.localizedDescription.contains(reference.id.uuidString.lowercased()))
        }
    }

    func testSecretsResolveOnlyDuringEnvironmentPreparation() async throws {
        let reference = EnvironmentSecretReference()
        let resolver = RecordingSecretResolver(
            values: [reference: SecretValue("resolved-secret")]
        )
        let preparer = LaunchEnvironmentPreparer(
            policy: .safeDefault,
            identity: ChildEnvironmentIdentity(
                homeDirectory: "/Users/fixture",
                userName: "fixture",
                temporaryDirectory: "/private/tmp/fixture"
            ),
            processEnvironment: ["OPENAI_API_KEY": "parent-secret"],
            secretResolver: resolver
        )
        let assignments = [
            StoredEnvironmentAssignment(
                key: "OPENAI_API_KEY",
                value: .secretReference(reference)
            ),
            StoredEnvironmentAssignment(
                key: "CODEX_HOME",
                value: .literal("~/Codex")
            ),
            StoredEnvironmentAssignment(
                key: "LABEL",
                value: .literal("~/literal")
            ),
        ]

        let initialResolveCallCount = await resolver.resolveCallCount
        XCTAssertEqual(initialResolveCallCount, 0)
        let environment = try await preparer.prepare(assignments)

        let finalResolveCallCount = await resolver.resolveCallCount
        XCTAssertEqual(finalResolveCallCount, 1)
        XCTAssertEqual(environment["OPENAI_API_KEY"], "resolved-secret")
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/fixture/Codex")
        XCTAssertEqual(environment["LABEL"], "~/literal")
    }
}

private actor RecordingSecretResolver: SecretResolving {
    private let values: [EnvironmentSecretReference: SecretValue]
    private(set) var resolveCallCount = 0

    init(values: [EnvironmentSecretReference: SecretValue]) {
        self.values = values
    }

    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue {
        resolveCallCount += 1
        guard let value = values[reference] else {
            throw SecretStoreError.missing(reference)
        }
        return value
    }
}

private struct MissingSecretResolver: SecretResolving {
    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue {
        throw SecretStoreError.missing(reference)
    }
}
