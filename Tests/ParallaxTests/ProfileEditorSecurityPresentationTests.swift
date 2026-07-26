import XCTest
@testable import Parallax

final class ProfileEditorSecurityPresentationTests: XCTestCase {
    func testArgumentPreviewPreservesOrderAndRedactsKeychainReferences() throws {
        let reference = EnvironmentSecretReference(
            id: try XCTUnwrap(
                UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            )
        )

        let preview = ProfileEditorSecurityPresentation.argumentPreview(
            for: "first second first \(reference.token)"
        )

        XCTAssertEqual(
            preview,
            [
                "first",
                "second",
                "first",
                "<redacted Keychain reference>",
            ]
        )
    }

    func testEnvironmentPreviewPreservesOperationsAndRedactsSensitiveValues() throws {
        let reference = EnvironmentSecretReference(
            id: try XCTUnwrap(
                UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            )
        )
        let text = """
        PUBLIC=  meaningful whitespace
        OPENAI_API_KEY=literal-api-key
        unset PUBLIC
        CUSTOM_PRIVATE=custom-literal
        SERVICE_TOKEN=\(reference.token)
        """

        let preview = ProfileEditorSecurityPresentation.environmentPreview(
            for: text,
            explicitSensitiveKeys: ["CUSTOM_PRIVATE"],
            revealSensitiveLiterals: false
        )

        XCTAssertEqual(
            preview.map(\.text),
            [
                "PUBLIC=  meaningful whitespace",
                "OPENAI_API_KEY=<redacted>",
                "unset PUBLIC",
                "CUSTOM_PRIVATE=<redacted>",
                "SERVICE_TOKEN=<redacted>",
            ]
        )
        XCTAssertEqual(
            preview.map(\.isRevealable),
            [false, true, false, true, false]
        )
    }

    func testRevealShowsOnlySensitiveLiteralsAndNeverKeychainReferences() throws {
        let reference = EnvironmentSecretReference(
            id: try XCTUnwrap(
                UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            )
        )
        let text = """
        OPENAI_API_KEY=literal-api-key
        SERVICE_TOKEN=\(reference.token)
        """

        let preview = ProfileEditorSecurityPresentation.environmentPreview(
            for: text,
            explicitSensitiveKeys: [],
            revealSensitiveLiterals: true
        )

        XCTAssertEqual(
            preview.map(\.text),
            [
                "OPENAI_API_KEY=literal-api-key",
                "SERVICE_TOKEN=<redacted>",
            ]
        )
        XCTAssertFalse(preview.map(\.text).contains { $0.contains(reference.token) })
    }

    func testEffectivePreviewMatchesSafeChildEnvironmentAndUnsets() {
        let preview = ProfileEditorSecurityPresentation.environmentPreview(
            for: "LABEL=~/literal\nCODEX_HOME=~/Codex\nunset LANG",
            explicitSensitiveKeys: [],
            revealSensitiveLiterals: false,
            childEnvironmentPolicy: .safeDefault,
            identity: ChildEnvironmentIdentity(
                homeDirectory: "/Users/fixture",
                userName: "fixture",
                temporaryDirectory: "/private/tmp/fixture"
            ),
            processEnvironment: [
                "LANG": "en_US.UTF-8",
                "OPENAI_API_KEY": "must-not-leak",
                "CODEX_HOME": "/hidden/codex",
            ]
        )
        let values = Dictionary(
            uniqueKeysWithValues: preview.map { line in
                let parts = line.text.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                return (
                    String(parts[0]),
                    parts.count == 2 ? String(parts[1]) : ""
                )
            }
        )

        XCTAssertEqual(values["HOME"], "/Users/fixture")
        XCTAssertEqual(values["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(values["LABEL"], "~/literal")
        XCTAssertEqual(values["CODEX_HOME"], "/Users/fixture/Codex")
        XCTAssertNil(values["LANG"])
        XCTAssertNil(values["OPENAI_API_KEY"])
    }

    func testDiagnosticLocationDescriptionIncludesFullRange() {
        let range = LaunchSourceRange(
            start: LaunchSourceLocation(
                utf16Offset: 7,
                line: 2,
                column: 4
            ),
            end: LaunchSourceLocation(
                utf16Offset: 13,
                line: 2,
                column: 10
            )
        )

        XCTAssertEqual(
            ProfileEditorSecurityPresentation.locationDescription(range),
            "Line 2, columns 4–9"
        )
    }

    func testSensitivityOptionsReflectEffectiveValuesAndInherentProtection() throws {
        let reference = EnvironmentSecretReference(
            id: try XCTUnwrap(
                UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
            )
        )
        let text = """
        Z_PUBLIC=visible
        REMOVED=old
        OPENAI_API_KEY=literal-api-key
        SERVICE_REFERENCE=\(reference.token)
        unset REMOVED
        """

        let options =
            ProfileEditorSecurityPresentation.environmentSensitivityOptions(
                for: text
            )

        XCTAssertEqual(
            options.map(\.key),
            ["OPENAI_API_KEY", "SERVICE_REFERENCE", "Z_PUBLIC"]
        )
        XCTAssertEqual(
            options.map(\.isKeychainReference),
            [false, true, false]
        )
        XCTAssertEqual(
            options.map(\.isAutomaticallySensitive),
            [true, true, false]
        )
    }

    func testUpdatingSensitiveKeysCanonicalizesAndSortsDeterministically() {
        let added = ProfileEditorSecurityPresentation.updatingSensitiveKeys(
            ["z_private", "CUSTOM"],
            key: "custom",
            isSensitive: true
        )

        XCTAssertEqual(added, ["CUSTOM", "Z_PRIVATE"])

        let removed = ProfileEditorSecurityPresentation.updatingSensitiveKeys(
            added,
            key: "Z_private",
            isSensitive: false
        )

        XCTAssertEqual(removed, ["CUSTOM"])
    }
}
