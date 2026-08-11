import XCTest
@testable import Parallax

final class LibraryImportValidatorTests: XCTestCase {
    func testValidCurrentDocumentProducesValidatedDocument() throws {
        let report = LibraryImportValidator().validate(try validDocumentData())

        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.document?.applications.count, 1)
        XCTAssertEqual(report.document?.applications.first?.profiles.count, 1)
    }

    func testByteLimitRunsBeforeJSONParsing() {
        let validator = LibraryImportValidator(
            limits: LibraryImportLimits(maximumBytes: 8)
        )
        let report = validator.validate(Data("not-json-over-limit".utf8))

        XCTAssertEqual(report.issues.map(\.code), [.inputTooLarge])
        XCTAssertNil(report.document)
    }

    func testMalformedAndUnsupportedDocumentsAreRejected() throws {
        let malformed = LibraryImportValidator().validate(
            Data(#"{"version":2"#.utf8)
        )
        var futureObject = try validJSONObject()
        futureObject["version"] = LibraryDocument.currentVersion + 1
        let future = LibraryImportValidator().validate(
            try encoded(futureObject)
        )
        var zeroObject = try validJSONObject()
        zeroObject["version"] = 0
        let zero = LibraryImportValidator().validate(try encoded(zeroObject))

        XCTAssertEqual(malformed.issues.map(\.code), [.malformedJSON])
        XCTAssertTrue(future.issues.contains { $0.code == .unsupportedVersion })
        XCTAssertTrue(zero.issues.contains { $0.code == .invalidVersion })
        XCTAssertNil(future.document)
        XCTAssertNil(zero.document)
    }

    func testNonObjectEnvelopeIsRejectedWithoutRunningLaterPhases() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["not", "a", "library"]
        )

        let report = LibraryImportValidator().validate(data)

        XCTAssertEqual(report.issues.map(\.code), [.invalidTopLevel])
        XCTAssertEqual(report.issues.map(\.path), ["$"])
        XCTAssertNil(report.document)
    }

    func testBooleanValuesAreNotAcceptedAsJSONNumbers() throws {
        var versionObject = try validJSONObject()
        versionObject["version"] = true
        let versionReport = LibraryImportValidator().validate(
            try encoded(versionObject)
        )

        var revisionObject = try validJSONObject()
        revisionObject["revision"] = true
        let revisionReport = LibraryImportValidator().validate(
            try encoded(revisionObject)
        )

        XCTAssertTrue(
            versionReport.issues.contains {
                $0.code == .invalidFieldType && $0.path == "$.version"
            }
        )
        XCTAssertTrue(
            revisionReport.issues.contains {
                $0.code == .invalidFieldValue && $0.path == "$.revision"
            }
        )
        XCTAssertNil(versionReport.document)
        XCTAssertNil(revisionReport.document)
    }

    func testTypedDecodeFailureRemainsLastAfterRawSchemaIssues() throws {
        var object = try validJSONObject()
        var applications = try XCTUnwrap(
            object["applications"] as? [[String: Any]]
        )
        applications[0].removeValue(forKey: "displayName")
        var profiles = try XCTUnwrap(
            applications[0]["profiles"] as? [[String: Any]]
        )
        profiles[0]["lastLaunchedAt"] = "not-an-encoded-date"
        applications[0]["profiles"] = profiles
        object["applications"] = applications

        let report = LibraryImportValidator().validate(try encoded(object))

        XCTAssertEqual(report.issues.first?.code, .missingRequiredField)
        XCTAssertEqual(report.issues.last?.code, .decodingFailed)
        XCTAssertNil(report.document)
    }

    func testValidatedDocumentUsesNormalizedDisplayNames() throws {
        var object = try validJSONObject()
        var applications = try XCTUnwrap(
            object["applications"] as? [[String: Any]]
        )
        applications[0]["displayName"] = "  Cafe\u{301}  "
        var profiles = try XCTUnwrap(
            applications[0]["profiles"] as? [[String: Any]]
        )
        profiles[0]["name"] = "  Re\u{301}sume\u{301}  "
        applications[0]["profiles"] = profiles
        object["applications"] = applications

        let report = LibraryImportValidator().validate(try encoded(object))

        XCTAssertTrue(report.isValid)
        XCTAssertEqual(report.document?.applications[0].displayName, "Caf\u{e9}")
        XCTAssertEqual(
            report.document?.applications[0].profiles[0].name,
            "R\u{e9}sum\u{e9}"
        )
        XCTAssertEqual(
            report.issues.filter { $0.code == .normalizedDisplayName }.count,
            2
        )
    }

    func testAggregatesRequiredPresetPathAndLaunchConfigurationIssues() throws {
        var object = try validJSONObject()
        var applications = try XCTUnwrap(object["applications"] as? [[String: Any]])
        var application = try XCTUnwrap(applications.first)
        application.removeValue(forKey: "displayName")
        application["preset"] = "not-a-preset"
        application["appPath"] = "relative/Fixture.app"
        application["baseStoragePath"] = "/FixtureData/../Escaped"
        application["storageID"] = "Archives"

        var profiles = try XCTUnwrap(application["profiles"] as? [[String: Any]])
        var profile = try XCTUnwrap(profiles.first)
        profile["name"] = ""
        profile["storageName"] = "../legacy"
        profile["argumentsText"] =
            "--user-data-dir=/one --user-data-dir /two"
        profile["environmentText"] = "1INVALID=value\nCODEX_HOME=../relative"
        profiles[0] = profile
        application["profiles"] = profiles
        applications[0] = application
        object["applications"] = applications

        let report = LibraryImportValidator().validate(try encoded(object))
        let codes = Set(report.issues.map(\.code))

        XCTAssertTrue(codes.contains(.missingRequiredField))
        XCTAssertTrue(codes.contains(.invalidPreset))
        XCTAssertTrue(codes.contains(.invalidApplicationPath))
        XCTAssertTrue(codes.contains(.invalidBaseStoragePath))
        XCTAssertTrue(codes.contains(.invalidStorageIdentity))
        XCTAssertTrue(codes.contains(.emptyRequiredString))
        XCTAssertTrue(codes.contains(.forbiddenLegacyStorageName))
        XCTAssertTrue(codes.contains(.invalidArguments))
        XCTAssertTrue(codes.contains(.invalidEnvironment))
        XCTAssertTrue(codes.contains(.invalidIsolationPath))
        XCTAssertGreaterThanOrEqual(report.issues.count, 10)
        XCTAssertNil(report.document)
    }

    func testAggregatesDuplicateAndCrossRoleIdentityReuse() throws {
        let applicationID = UUID()
        let applicationStorageID = UUID()
        let duplicatedProfileID = UUID()
        let duplicatedProfileStorageID = UUID()
        let application = ManagedApplication(
            id: applicationID,
            storageID: applicationStorageID,
            displayName: "One",
            appPath: "/Applications/One.app",
            preset: .custom,
            profiles: [
                LaunchProfile(
                    id: duplicatedProfileID,
                    storageID: duplicatedProfileStorageID,
                    name: "One"
                ),
                LaunchProfile(
                    id: duplicatedProfileID,
                    storageID: duplicatedProfileStorageID,
                    name: "Two"
                )
            ]
        )
        let second = ManagedApplication(
            id: applicationID,
            storageID: applicationStorageID,
            displayName: "Two",
            appPath: "/Applications/Two.app",
            preset: .custom,
            profiles: [
                LaunchProfile(
                    id: applicationID,
                    storageID: applicationStorageID,
                    name: "Cross type"
                )
            ]
        )
        let data = try JSONEncoder().encode(
            LibraryDocument(applications: [application, second])
        )
        let report = LibraryImportValidator().validate(data)
        let codes = Set(report.issues.map(\.code))

        XCTAssertTrue(codes.contains(.duplicateApplicationID))
        XCTAssertTrue(codes.contains(.duplicateApplicationStorageID))
        XCTAssertTrue(codes.contains(.duplicateProfileID))
        XCTAssertTrue(codes.contains(.duplicateProfileStorageID))
        XCTAssertTrue(codes.contains(.crossTypeIdentityReuse))
        XCTAssertNil(report.document)
    }

    func testCountAndStringLimitsAreAggregated() throws {
        let limits = LibraryImportLimits(
            maximumBytes: 1_000_000,
            maximumApplications: 1,
            maximumProfilesPerApplication: 1,
            maximumProfilesTotal: 1,
            maximumNameUTF8Bytes: 4,
            maximumBundleIdentifierUTF8Bytes: 8,
            maximumPathUTF8Bytes: 16,
            maximumTextUTF8Bytes: 8,
            maximumSensitiveEnvironmentKeys: 1
        )
        let longProfile = LaunchProfile(
            name: "Profile name is long",
            argumentsText: "arguments are long",
            environmentText: "ENVIRONMENT=long",
            notes: "notes are long",
            sensitiveEnvironmentKeys: ["FIRST_KEY", "SECOND_KEY"]
        )
        let applications = [
            ManagedApplication(
                displayName: "Application name is long",
                bundleIdentifier: "com.example.identifier",
                appPath: "/Applications/Very Long Fixture Name.app",
                preset: .custom,
                profiles: [longProfile, longProfile.duplicatedWithFreshIdentity()]
            ),
            ManagedApplication(
                displayName: "Second",
                appPath: "/Applications/Second.app",
                preset: .custom
            )
        ]
        let data = try JSONEncoder().encode(
            LibraryDocument(applications: applications)
        )

        let report = LibraryImportValidator(limits: limits).validate(data)
        let codes = Set(report.issues.map(\.code))

        XCTAssertTrue(codes.contains(.tooManyApplications))
        XCTAssertTrue(codes.contains(.tooManyProfiles))
        XCTAssertTrue(codes.contains(.stringTooLong))
        XCTAssertTrue(codes.contains(.tooManySensitiveEnvironmentKeys))
        XCTAssertNil(report.document)
    }

    func testNormalizedNameCollisionsAreWarningsAndRemainReviewable() throws {
        let applications = [
            ManagedApplication(
                displayName: "Fixture",
                appPath: "/Applications/Fixture One.app",
                preset: .custom,
                profiles: [
                    LaunchProfile(name: "Work"),
                    LaunchProfile(name: "work")
                ]
            ),
            ManagedApplication(
                displayName: "fixture",
                appPath: "/Applications/Fixture Two.app",
                preset: .custom
            )
        ]
        let report = LibraryImportValidator().validate(
            try JSONEncoder().encode(
                LibraryDocument(applications: applications)
            )
        )

        XCTAssertTrue(report.isValid)
        XCTAssertNotNil(report.document)
        XCTAssertEqual(
            report.issues.filter { $0.code == .normalizedNameCollision }.count,
            2
        )
        XCTAssertTrue(
            report.issues
                .filter { $0.code == .normalizedNameCollision }
                .allSatisfy { $0.severity == .warning }
        )
    }

    func testCanonicalAbsoluteAppPathIsRequiredWithoutFilesystemAccess() throws {
        for invalidPath in [
            "",
            "Fixture.app",
            "/Applications/../Fixture.app",
            "/Applications//Fixture.app",
            "/Applications/Fixture"
        ] {
            var object = try validJSONObject()
            var applications = try XCTUnwrap(
                object["applications"] as? [[String: Any]]
            )
            applications[0]["appPath"] = invalidPath
            object["applications"] = applications

            let report = LibraryImportValidator().validate(try encoded(object))

            XCTAssertTrue(
                report.issues.contains { $0.code == .invalidApplicationPath },
                "Expected rejection for \(invalidPath)"
            )
            XCTAssertNil(report.document)
        }
    }

    func testLegacyAndApprovedLaunchTrustRepresentationsAreAccepted() throws {
        for legacyState in ["local", "importedPendingReview"] {
            var object = try validJSONObject()
            var applications = try XCTUnwrap(
                object["applications"] as? [[String: Any]]
            )
            var profiles = try XCTUnwrap(
                applications[0]["profiles"] as? [[String: Any]]
            )
            profiles[0]["launchConfigurationTrust"] = legacyState
            applications[0]["profiles"] = profiles
            object["applications"] = applications

            let report = LibraryImportValidator().validate(try encoded(object))

            XCTAssertTrue(report.isValid, "Expected support for \(legacyState)")
        }

        let approval = ImportedLaunchApproval(
            configurationFingerprint: ImportedLaunchConfigurationFingerprint(
                sha256: String(repeating: "a", count: 64)
            ),
            approvedAt: Date(timeIntervalSince1970: 1_234)
        )
        let approvedProfile = LaunchProfile(
            name: "Approved",
            launchConfigurationTrust: .importedApproved(approval)
        )
        let approvedDocument = LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: "Approved Fixture",
                    appPath: "/Applications/Approved Fixture.app",
                    preset: .custom,
                    profiles: [approvedProfile]
                )
            ]
        )

        let approvedReport = LibraryImportValidator().validate(
            try JSONEncoder().encode(approvedDocument)
        )

        XCTAssertTrue(approvedReport.isValid)
        XCTAssertEqual(
            approvedReport.document?.applications.first?
                .profiles.first?.launchConfigurationTrust,
            .importedApproved(approval)
        )
    }

    func testMalformedLaunchTrustApprovalAggregatesStructuralIssues() throws {
        var object = try validJSONObject()
        var applications = try XCTUnwrap(
            object["applications"] as? [[String: Any]]
        )
        var profiles = try XCTUnwrap(
            applications[0]["profiles"] as? [[String: Any]]
        )
        profiles[0]["launchConfigurationTrust"] = [
            "state": "importedApproved",
            "approval": [
                "configurationFingerprint": ["sha256": "not-a-fingerprint"]
            ]
        ]
        applications[0]["profiles"] = profiles
        object["applications"] = applications

        let report = LibraryImportValidator().validate(try encoded(object))

        XCTAssertTrue(
            report.issues.contains {
                $0.code == .invalidFieldValue
                    && $0.path.hasSuffix(
                        ".approval.configurationFingerprint.sha256"
                    )
            }
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.code == .missingRequiredField
                    && $0.path.hasSuffix(".approval.approvedAt")
            }
        )
        XCTAssertNil(report.document)
    }

    func testUnsupportedLaunchTrustShapeIsRejectedBeforeDecode() throws {
        var object = try validJSONObject()
        var applications = try XCTUnwrap(
            object["applications"] as? [[String: Any]]
        )
        var profiles = try XCTUnwrap(
            applications[0]["profiles"] as? [[String: Any]]
        )
        profiles[0]["launchConfigurationTrust"] = [
            "state": "trustedWithoutReview"
        ]
        applications[0]["profiles"] = profiles
        object["applications"] = applications

        let report = LibraryImportValidator().validate(try encoded(object))

        XCTAssertTrue(
            report.issues.contains {
                $0.code == .invalidFieldValue
                    && $0.path.hasSuffix(".launchConfigurationTrust.state")
            }
        )
        XCTAssertNil(report.document)
    }

    func testOptionalSecurityMetadataIsStructurallyValidated() throws {
        var object = try validJSONObject()
        var applications = try XCTUnwrap(
            object["applications"] as? [[String: Any]]
        )
        var profiles = try XCTUnwrap(
            applications[0]["profiles"] as? [[String: Any]]
        )
        profiles[0]["childEnvironmentPolicy"] = 42
        profiles[0]["isolationOwnership"] = [
            "userData": "unknownAuthority"
        ]
        profiles[0]["sensitiveEnvironmentKeys"] = [
            "VALID_KEY",
            "1INVALID",
            42
        ]
        applications[0]["profiles"] = profiles
        object["applications"] = applications

        let report = LibraryImportValidator().validate(try encoded(object))

        XCTAssertTrue(
            report.issues.contains {
                $0.code == .invalidFieldType
                    && $0.path.hasSuffix(".childEnvironmentPolicy")
            }
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.code == .invalidFieldValue
                    && $0.path.hasSuffix(".isolationOwnership.userData")
            }
        )
        XCTAssertTrue(
            report.issues.contains {
                $0.code == .missingRequiredField
                    && $0.path.hasSuffix(".isolationOwnership.codexHome")
            }
        )
        XCTAssertEqual(
            report.issues.filter {
                $0.path.contains(".sensitiveEnvironmentKeys")
            }.count,
            2
        )
        XCTAssertNil(report.document)
    }

    private func validDocumentData() throws -> Data {
        try JSONEncoder().encode(
            LibraryDocument(
                applications: [
                    ManagedApplication(
                        displayName: "Fixture",
                        bundleIdentifier: "com.example.fixture",
                        appPath: "/Applications/Fixture.app",
                        preset: .custom,
                        baseStoragePath: "/FixtureData/Profiles",
                        profiles: [
                            LaunchProfile(
                                name: "Work",
                                argumentsText:
                                    "--user-data-dir=/FixtureData/External/UserData",
                                environmentText:
                                    "CODEX_HOME=/FixtureData/External/CodexHome"
                            )
                        ]
                    )
                ]
            )
        )
    }

    private func validJSONObject() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: validDocumentData()
            ) as? [String: Any]
        )
    }

    private func encoded(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
