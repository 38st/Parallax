import XCTest

@testable import Parallax

final class LaunchConfigurationAuditRegressionTests: XCTestCase {
    func testDashOnlyArgumentsDoNotCrashSecretClassification() {
        let parsed = LaunchArgumentParser.parse("- -- --- -=")
        XCTAssertTrue(
            SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(in: parsed.tokens)
                .isEmpty)
    }

    func testManagedSwitchPrecedesTerminatorAndPreservesPositionals() {
        let parsed = LaunchArgumentParser.parse(
            "--flag -- --user-data-dir=/positional file")
        let resolution = UserDataDirectoryOptionResolver.resolve(in: parsed.tokens)
        XCTAssertTrue(resolution.occurrences.isEmpty)
        XCTAssertEqual(
            LaunchConfigurationProjection.preparedArguments(
                parsed.words, resolution: resolution,
                isolation: LaunchIsolationAnalysis(
                    userData: .managed(URL(fileURLWithPath: "/managed")), codexHome: nil
                )
            ),
            [
                "--flag", "--user-data-dir=/managed", "--",
                "--user-data-dir=/positional", "file",
            ]
        )
    }

    func testSingleDashSwitchIsCountedAndManagedSwitchIsLast() {
        let parsed = LaunchArgumentParser.parse("-user-data-dir /old --flag -- file")
        let resolution = UserDataDirectoryOptionResolver.resolve(in: parsed.tokens)
        XCTAssertEqual(resolution.resolvedValue, "/old")
        XCTAssertEqual(
            LaunchConfigurationProjection.preparedArguments(
                parsed.words, resolution: resolution,
                isolation: LaunchIsolationAnalysis(
                    userData: .managed(URL(fileURLWithPath: "/managed")), codexHome: nil
                )
            ),
            ["--flag", "--user-data-dir=/managed", "--", "file"]
        )
        let duplicate = UserDataDirectoryOptionResolver.resolve(
            in: LaunchArgumentParser.parse("--user-data-dir=/one -user-data-dir=/two")
                .tokens
        )
        XCTAssertEqual(duplicate.diagnostics.map(\.code), [.duplicateUserDataDirectory])
    }

    func testSplitSwitchIsEmittedAsOneEqualsToken() {
        let parsed = LaunchArgumentParser.parse(
            "--before --user-data-dir '/external path' --after")
        let path = URL(fileURLWithPath: "/external path")
        XCTAssertEqual(
            LaunchConfigurationProjection.preparedArguments(
                parsed.words,
                resolution: UserDataDirectoryOptionResolver.resolve(in: parsed.tokens),
                isolation: LaunchIsolationAnalysis(
                    userData: .external(
                        ExternalIsolationPath(requestedURL: path, canonicalURL: path)),
                    codexHome: nil
                )
            ),
            ["--before", "--user-data-dir=/external path", "--after"]
        )
    }

    func testBackslashNewlineIsAContinuationOutsideSingleQuotes() {
        let parsed = LaunchArgumentParser.parse(
            "--flag \\\n--api-key=fixture \\\n--user-data-dir=/fixture")
        XCTAssertEqual(
            parsed.words, ["--flag", "--api-key=fixture", "--user-data-dir=/fixture"])
        XCTAssertEqual(
            SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(in: parsed.tokens),
            [1])
        XCTAssertEqual(
            UserDataDirectoryOptionResolver.resolve(in: parsed.tokens).resolvedValue,
            "/fixture")
        XCTAssertEqual(
            LaunchArgumentParser.parse("\"a\\\nb\" 'a\\\nb' \\\n").words,
            ["ab", "a\\\nb"])
        XCTAssertEqual(LaunchArgumentParser.parse("\\\n x").words, ["x"])
    }

    func testCRLFContinuationExposesOptionsToValidation() {
        let parsed = LaunchArgumentParser.parse(
            "--flag \\\r\n--api-key=fixture \\\r\n--user-data-dir=/fixture"
        )
        XCTAssertEqual(
            parsed.words, ["--flag", "--api-key=fixture", "--user-data-dir=/fixture"])
        XCTAssertEqual(
            SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(in: parsed.tokens),
            [1])
        XCTAssertEqual(
            UserDataDirectoryOptionResolver.resolve(in: parsed.tokens).resolvedValue,
            "/fixture")
        XCTAssertEqual(
            LaunchArgumentParser.parse("\"a\\\r\nb\" 'a\\\r\nb'").words,
            ["ab", "a\\\r\nb"])
    }

    func testEnvironmentParserAcceptsTrailingCarriageReturn() {
        let parsed = LaunchEnvironmentParser.parse("VALUE=ok\r")
        XCTAssertFalse(parsed.hasErrors)
        XCTAssertEqual(parsed.effectiveValues["VALUE"], "ok")
    }

    func testUserOnlyURLsAndMailtoAreNotCredentials() {
        for text in [
            "--folder-uri=vscode-remote://ssh-remote+me@host/path",
            "--remote=ssh://me@host/path",
            "mailto:me@example.com",
            "--contact=mailto:me@example.com",
        ] {
            let parsed = LaunchArgumentParser.parse(text)
            XCTAssertTrue(
                SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(in: parsed.tokens)
                    .isEmpty, text)
        }
    }

    func testSecretKeyOptionNamesAreSensitive() {
        for text in [
            "--secret-key=fixture", "--aws-secret-key=fixture", "--secret-key fixture",
        ] {
            let parsed = LaunchArgumentParser.parse(text)
            XCTAssertFalse(
                SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(in: parsed.tokens)
                    .isEmpty, text)
        }
    }

    func testOmittingPositionalCredentialPreservesBooleanFlag() throws {
        let sanitized = try SensitiveConfigurationTextSanitizer().sanitizeArguments(
            "--incognito https://u:p@host", policy: .omit
        )
        XCTAssertEqual(
            LaunchArgumentParser.parse(sanitized.text).words, ["--incognito"])
    }

    func testTrailingEscapeCannotBeOverridden() throws {
        let diagnostic = try XCTUnwrap(
            LaunchArgumentParser.parse("value\\").diagnostics.first)
        XCTAssertFalse(
            LaunchConfigurationProjection.compilerDiagnostic(diagnostic).isOverridable)
    }

    func testAlternativeEnvironmentNewlinesBlockEvenInsideComments() {
        for separator in ["\u{2028}", "\u{2029}", "\u{85}", "\r", "\u{b}", "\u{c}"] {
            for prefix in ["# note", "VALUE=note"] {
                let parsed = LaunchEnvironmentParser.parse(
                    prefix + separator + "DYLD_INSERT_LIBRARIES=/fixture")
                XCTAssertTrue(parsed.hasErrors, separator.debugDescription)
                XCTAssertEqual(
                    parsed.diagnostics.map(\.code), [.unsupportedControlCharacter])
            }
        }
        XCTAssertFalse(
            LaunchEnvironmentParser.parse("VALUE=ok\r\nOTHER=yes\n").hasErrors)
    }

    @MainActor
    func testEnvironmentRewritePreservesUnmatchedBytesAndWhitespace() throws {
        let text = " # note\r\nVALUE=ends with space \r\nCLAUDE_CONFIG_DIR=/old\r\n\r\n"
        XCTAssertEqual(
            try LibraryStore.settingEnvironmentValue(
                "CLAUDE_CONFIG_DIR", to: "/new", in: text),
            text.replacingOccurrences(
                of: "CLAUDE_CONFIG_DIR=/old", with: "CLAUDE_CONFIG_DIR=/new")
        )
        XCTAssertEqual(
            LibraryStore.appendingEnvironmentLine("NEXT=yes", to: "VALUE=tail "),
            "VALUE=tail \nNEXT=yes")
        let hostile = "# note\u{2028}DYLD_INSERT_LIBRARIES=/fixture\nCLAUDE_CONFIG_DIR="
        XCTAssertEqual(
            try LibraryStore.settingEnvironmentValue(
                "CLAUDE_CONFIG_DIR", to: "/safe", in: hostile), hostile + "/safe")
    }

    @MainActor
    func testEnvironmentRewriteRejectsInjectedLines() {
        for separator in ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"] {
            XCTAssertThrowsError(
                try LibraryStore.settingEnvironmentValue(
                    "CODEX_HOME", to: "/folder" + separator + "INJECTED=yes",
                    in: "CODEX_HOME=/old"
                )
            ) { error in
                XCTAssertTrue(error is LaunchConfigurationTextError)
            }
        }
    }

    @MainActor
    func testArgumentRewriteHandlesSplitFormAndPreservesInvalidText() {
        let updated = LibraryStore.settingArgument(
            named: "--user-data-dir", to: "/new",
            in: "--user-data-dir '/old path' --flag")
        XCTAssertEqual(
            LaunchArgumentParser.parse(updated).words,
            ["--user-data-dir=/new", "--flag"])
        let invalid = "--user-data-dir=/external 'unfinished"
        XCTAssertEqual(
            LibraryStore.settingArgument(
                named: "--user-data-dir", to: "/new", in: invalid), invalid)
        XCTAssertEqual(
            LaunchArgumentParser.parse(
                LibraryStore.appendingArgument("next", to: "foo\\ ")
            ).words,
            ["foo ", "next"]
        )
    }

    func testCredentialOptionValuesAndCamelCaseOptionsAreSensitive() {
        for text in [
            "--db-url=postgres://u:p@h/db", "--proxy-server=http://u:p@host",
            "--apiKey=fixture", "--accessToken fixture",
        ] {
            XCTAssertFalse(
                SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(
                    in: LaunchArgumentParser.parse(text).tokens
                ).isEmpty, text)
        }
    }

    func testBareAndSuffixedSecretNamesAreSensitiveButPublicKeysAreNot() {
        let classifier = SensitiveEnvironmentKeyClassifier()
        for name in [
            "API_KEY", "PASSWORD", "TOKEN", "SECRET", "PRIVATE_KEY", "ACCESS_KEY",
            "CREDENTIALS", "SECRET_KEY", "STRIPE_SECRET_KEY",
        ] {
            XCTAssertTrue(classifier.isSensitive(name), name)
        }
        XCTAssertFalse(classifier.isSensitive("PUBLIC_KEY"))
        XCTAssertFalse(classifier.isSensitive("SERVICE_PUBLIC_KEY"))
    }

    func testOmittingSensitiveTwoTokenOptionsLeavesValidArguments() throws {
        let omitted = try SensitiveConfigurationTextSanitizer().sanitizeArguments(
            "--api-key fixture --label=safe", policy: .omit)
        XCTAssertEqual(LaunchArgumentParser.parse(omitted.text).words, ["--label=safe"])
        XCTAssertTrue(
            SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(
                in: LaunchArgumentParser.parse(omitted.text).tokens
            ).isEmpty)
    }

    func testCredentialHeadersAndSchemelessAuthoritiesAreSensitive() {
        for text in [
            "--header 'Authorization: Bearer fixture'",
            "--header='Authorization: Basic fixture'", "--proxy-server=u:p@host",
            "u:p@host",
        ] {
            XCTAssertFalse(
                SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(
                    in: LaunchArgumentParser.parse(text).tokens
                ).isEmpty, text)
        }
    }

    func testCredentialValuesAreRedactedUnderOrdinaryEnvironmentNames() throws {
        let assignments = [
            StoredEnvironmentAssignment(
                key: "REDIS_URL", value: .literal("redis://u:p@host"))
        ]
        let policy = EnvironmentDisclosurePolicy()
        XCTAssertEqual(policy.preview(assignments).first?.displayValue, .redacted)
        XCTAssertTrue(policy.export(assignments, sensitiveLiteralPolicy: .omit).isEmpty)
        let sanitized = try SensitiveConfigurationTextSanitizer().sanitizeEnvironment(
            "REDIS_URL=redis://u:p@host", explicitSensitiveKeys: [], policy: .redact)
        XCTAssertTrue(sanitized.containsSensitiveContent)
        XCTAssertEqual(sanitized.text, "REDIS_URL=<redacted>")
    }

    func testInheritedXPCDynamicLoaderVariablesAreScrubbed() {
        let environment = ChildEnvironmentPolicy.inheritProcessEnvironment
            .baseEnvironment(
                processEnvironment: [
                    "__XPC_DYLD_INSERT_LIBRARIES": "/fixture", "KEEP": "yes",
                ],
                identity: ChildEnvironmentIdentity(
                    homeDirectory: "/fixture", userName: "fixture",
                    temporaryDirectory: "/tmp/fixture")
            )
        XCTAssertNil(environment["__XPC_DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(environment["KEEP"], "yes")
    }

    func testClaudeBundleIdentityWinsOverCodexDisplayName() {
        XCTAssertEqual(
            AppPreset.detected(
                displayName: "Codex", bundleIdentifier: "com.anthropic.claudefordesktop"
            ), .claude)
    }

    func testPresetRefreshPreservesPositionalsAndReplacesSingleDashSwitch() throws {
        let profile = LaunchProfile(
            name: "Fixture",
            argumentsText: "-user-data-dir /old --flag -- --user-data-dir=/positional",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated, codexHome: .explicit)
        )
        let application = ManagedApplication(
            displayName: "Fixture", appPath: "/fixture/App.app", preset: .chrome,
            profiles: [profile]
        )
        let service = PresetChangePreviewService()
        let preview = try service.preview(
            application: application,
            targetPreset: .chrome,
            generatedPaths: [
                PresetGeneratedPaths(
                    profileID: profile.id, profileStorageID: profile.storageID,
                    userDataDirectory: "/managed", codexHome: "/managed-codex"
                )
            ]
        )
        let result = try service.applyingAuthorizedRefresh(
            preview,
            authorization: service.authorizeRefresh(
                preview, acknowledging: .applyListedGeneratedValueChanges),
            to: application
        )
        XCTAssertEqual(
            result.profiles.first?.arguments,
            ["--flag", "--user-data-dir=/managed", "--", "--user-data-dir=/positional"]
        )
    }
}
