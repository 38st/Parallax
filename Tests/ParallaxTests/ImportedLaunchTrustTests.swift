import Foundation
import XCTest
@testable import Parallax

final class ImportedLaunchTrustTests: XCTestCase {
    func testLegacyTrustStringsAndMissingTrustRemainBackwardCompatible() throws {
        let local = LaunchProfile(
            id: fixedUUID("10000000-0000-4000-8000-000000000001"),
            storageID: fixedUUID("20000000-0000-4000-8000-000000000001"),
            name: "Local"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedLocal = try encoder.encode(local)
        let localObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedLocal)
                as? [String: Any]
        )
        XCTAssertEqual(
            localObject["launchConfigurationTrust"] as? String,
            "local"
        )
        XCTAssertEqual(
            try encoder.encode(
                LaunchConfigurationTrust.importedPendingReview
            ),
            Data(#""importedPendingReview""#.utf8)
        )

        var legacyObject = localObject
        legacyObject.removeValue(forKey: "launchConfigurationTrust")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(
            try JSONDecoder().decode(
                LaunchProfile.self,
                from: legacyData
            ).launchConfigurationTrust,
            .local
        )

        legacyObject["launchConfigurationTrust"] = "importedPendingReview"
        let pendingData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(
            try JSONDecoder().decode(
                LaunchProfile.self,
                from: pendingData
            ).launchConfigurationTrust,
            .importedPendingReview
        )
    }

    func testReviewContainsDetailedAuthorityButNeverEnvironmentValues() {
        let source = trustSource(
            environmentText: """
            PUBLIC_VALUE=visible-but-private
            DYLD_INSERT_LIBRARIES=/tmp/loader.dylib
            NSZombieEnabled=YES
            OPENAI_API_KEY=super-secret-api-value
            unset REMOVED_TOKEN
            """
        )

        let review = ImportedLaunchTrust().review(for: source)

        XCTAssertEqual(review.application.displayName, "Imported Browser")
        XCTAssertEqual(
            review.application.canonicalPath,
            "/Applications/Imported Browser.app"
        )
        XCTAssertEqual(review.application.expectedBundleIdentifier, "example.browser")
        XCTAssertEqual(review.application.verifiedBundleIdentifier, "example.browser")
        XCTAssertEqual(review.arguments, ["--profile", "Imported Work"])
        XCTAssertEqual(
            review.environmentEntries.map(\.key),
            [
                "PUBLIC_VALUE",
                "DYLD_INSERT_LIBRARIES",
                "NSZombieEnabled",
                "OPENAI_API_KEY",
                "REMOVED_TOKEN",
            ]
        )
        XCTAssertEqual(
            review.environmentEntries.map(\.operation),
            [.set, .set, .set, .set, .unset]
        )
        XCTAssertEqual(
            review.environmentEntries[1].risks,
            [.dynamicLoader]
        )
        XCTAssertEqual(
            review.environmentEntries[2].risks,
            [.debugger]
        )
        XCTAssertEqual(
            review.environmentEntries[3].risks,
            [.sensitive]
        )
        XCTAssertTrue(review.environmentEntries[4].risks.isEmpty)
        XCTAssertEqual(
            review.isolationPaths.map(\.canonicalPath),
            [
                "/tmp/parallax/user-data",
                "/tmp/parallax/codex-home",
            ]
        )
        XCTAssertEqual(review.configuredBaseRoot, "/tmp/parallax")
        XCTAssertEqual(review.isolationOwnership, .explicit)

        let reflected = String(reflecting: review)
        XCTAssertFalse(reflected.contains("visible-but-private"))
        XCTAssertFalse(reflected.contains("/tmp/loader.dylib"))
        XCTAssertFalse(reflected.contains("super-secret-api-value"))
    }

    func testImportedApprovalRoundTripsAndIsFingerprintBound() throws {
        let service = ImportedLaunchTrust()
        let source = trustSource()
        let review = service.review(for: source)
        let approval = try service.approval(
            for: review,
            currentSource: source,
            approvedAt: Date(timeIntervalSince1970: 1_234)
        )
        var profile = profile(for: source)
        profile.markLaunchConfigurationImported()
        profile.approveImportedLaunch(using: approval)

        XCTAssertEqual(
            service.assessment(for: profile, source: source),
            .approved(approval)
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(
            LaunchProfile.self,
            from: encoded
        )
        XCTAssertEqual(decoded.launchConfigurationTrust, profile.launchConfigurationTrust)
        XCTAssertEqual(
            service.assessment(for: decoded, source: source),
            .approved(approval)
        )
    }

    func testImportedFingerprintHasStableGoldenVector() {
        XCTAssertEqual(
            ImportedLaunchTrust().fingerprint(for: trustSource()).sha256,
            "05d5f638a60223bb6aa766453a7cd3ce45b0b84205c0c82c4d00e8c7f69ddc56"
        )
    }

    func testRelevantProfileEditsImmediatelyInvalidateImportedApproval() throws {
        let service = ImportedLaunchTrust()
        let source = trustSource()
        let approval = try service.approval(
            for: service.review(for: source),
            currentSource: source
        )
        func approvedProfile() -> LaunchProfile {
            var result = profile(for: source)
            result.markLaunchConfigurationImported()
            result.approveImportedLaunch(using: approval)
            return result
        }

        var arguments = approvedProfile()
        arguments.argumentsText += " --changed"
        XCTAssertEqual(
            arguments.launchConfigurationTrust,
            .importedPendingReview
        )

        var environment = approvedProfile()
        environment.environmentText += "\nNEW_VALUE=changed"
        XCTAssertEqual(
            environment.launchConfigurationTrust,
            .importedPendingReview
        )

        var ownership = approvedProfile()
        ownership.isolationOwnership.userData = .generated
        XCTAssertEqual(
            ownership.launchConfigurationTrust,
            .importedPendingReview
        )

        var inheritance = approvedProfile()
        inheritance.childEnvironmentPolicy = .inheritProcessEnvironment
        XCTAssertEqual(
            inheritance.launchConfigurationTrust,
            .importedPendingReview
        )

        var sensitivity = approvedProfile()
        sensitivity.sensitiveEnvironmentKeys.append("PUBLIC_VALUE")
        XCTAssertEqual(
            sensitivity.launchConfigurationTrust,
            .importedPendingReview
        )
    }

    func testApplicationRetargetBaseRootAndIsolationChangesInvalidateApproval() throws {
        let service = ImportedLaunchTrust()
        let source = trustSource()
        let approval = try service.approval(
            for: service.review(for: source),
            currentSource: source
        )
        var profile = profile(for: source)
        profile.markLaunchConfigurationImported()
        profile.approveImportedLaunch(using: approval)

        let changedSources = [
            source.replacing(
                applicationID: fixedUUID(
                    "30000000-0000-4000-8000-000000000002"
                )
            ),
            source.replacing(
                applicationStorageID: fixedUUID(
                    "40000000-0000-4000-8000-000000000002"
                )
            ),
            source.replacing(
                canonicalApplicationURL: URL(
                    fileURLWithPath: "/Applications/Other Browser.app"
                )
            ),
            source.replacing(configuredBaseRoot: "/tmp/other-root"),
            source.replacing(
                isolationOwnership: ProfileIsolationOwnership(
                    userData: .generated,
                    codexHome: .explicit
                )
            ),
            source.replacing(expectedBundleIdentifier: "other.browser"),
            source.replacing(
                verifiedBundleIdentifier: "other.browser"
            ),
            source.replacing(
                profileStorageID: fixedUUID(
                    "60000000-0000-4000-8000-000000000002"
                )
            ),
            source.replacing(argumentsText: "--different"),
            source.replacing(environmentText: "PUBLIC_VALUE=different"),
            source.replacing(
                childEnvironmentPolicy: .inheritProcessEnvironment
            ),
            source.replacing(
                sensitiveEnvironmentKeys: ["PUBLIC_VALUE"]
            ),
            source.replacing(
                isolationPaths: [
                    ImportedLaunchIsolationPath(
                        role: .userData,
                        authority: .external,
                        canonicalURL: URL(
                            fileURLWithPath: "/tmp/external-user-data"
                        )
                    ),
                ]
            ),
        ]

        for changedSource in changedSources {
            guard case .reviewRequired =
                service.assessment(for: profile, source: changedSource)
            else {
                XCTFail("Changed launch authority must invalidate approval")
                continue
            }
        }
    }

    func testIdentityPreservationAllowsApprovalButNotImportedToLocalDowngrade() throws {
        let service = ImportedLaunchTrust()
        let source = trustSource()
        var persisted = profile(for: source)
        persisted.markLaunchConfigurationImported()
        let approval = try service.approval(
            for: service.review(for: source),
            currentSource: source
        )

        var approvedDraft = persisted
        approvedDraft.approveImportedLaunch(using: approval)
        XCTAssertEqual(
            approvedDraft.preservingIdentity(of: persisted)
                .launchConfigurationTrust,
            .importedApproved(approval)
        )

        var forgedLocalDraft = persisted
        forgedLocalDraft.launchConfigurationTrust = .local
        XCTAssertEqual(
            forgedLocalDraft.preservingIdentity(of: persisted)
                .launchConfigurationTrust,
            .importedPendingReview
        )
    }

    func testImportedMarkingAndDuplicationAlwaysRequireFreshReview() throws {
        let service = ImportedLaunchTrust()
        let source = trustSource()
        let approval = try service.approval(
            for: service.review(for: source),
            currentSource: source
        )
        var profile = profile(for: source)
        profile.markLaunchConfigurationImported()
        profile.approveImportedLaunch(using: approval)

        let duplicated = profile.duplicatedWithFreshIdentity()
        XCTAssertEqual(
            duplicated.launchConfigurationTrust,
            .importedPendingReview
        )

        profile.markLaunchConfigurationImported()
        XCTAssertEqual(
            profile.launchConfigurationTrust,
            .importedPendingReview
        )
    }

    func testStaleReviewCannotApproveRetargetedConfiguration() throws {
        let service = ImportedLaunchTrust()
        let source = trustSource()
        let review = service.review(for: source)
        let changed = source.replacing(
            environmentText: source.environmentText + "\nEXTRA=value"
        )

        XCTAssertThrowsError(
            try service.approval(
                for: review,
                currentSource: changed
            )
        ) { error in
            XCTAssertEqual(
                error as? ImportedLaunchTrustError,
                .configurationChangedAfterReview
            )
        }
    }

    func testReviewIsPureAndDoesNotCreateIsolationDirectories() {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = trustSource(
            isolationPaths: [
                ImportedLaunchIsolationPath(
                    role: .userData,
                    authority: .managed,
                    canonicalURL: temporaryRoot.appendingPathComponent(
                        "UserData",
                        isDirectory: true
                    )
                ),
            ]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.path))
        _ = ImportedLaunchTrust().review(for: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.path))
    }

    private func trustSource(
        environmentText: String = "PUBLIC_VALUE=plain",
        isolationPaths: [ImportedLaunchIsolationPath]? = nil
    ) -> ImportedLaunchTrustSource {
        ImportedLaunchTrustSource(
            applicationID: fixedUUID(
                "30000000-0000-4000-8000-000000000001"
            ),
            applicationStorageID: fixedUUID(
                "40000000-0000-4000-8000-000000000001"
            ),
            applicationDisplayName: "Imported Browser",
            canonicalApplicationURL: URL(
                fileURLWithPath: "/Applications/Imported Browser.app",
                isDirectory: true
            ),
            expectedBundleIdentifier: "example.browser",
            verifiedBundleIdentifier: "example.browser",
            profileID: fixedUUID(
                "50000000-0000-4000-8000-000000000001"
            ),
            profileStorageID: fixedUUID(
                "60000000-0000-4000-8000-000000000001"
            ),
            profileName: "Imported Work",
            configuredBaseRoot: "/tmp/parallax",
            argumentsText: "--profile \"Imported Work\"",
            environmentText: environmentText,
            isolationOwnership: .explicit,
            childEnvironmentPolicy: .safeDefault,
            sensitiveEnvironmentKeys: [],
            isolationPaths: isolationPaths ?? [
                ImportedLaunchIsolationPath(
                    role: .userData,
                    authority: .managed,
                    canonicalURL: URL(
                        fileURLWithPath: "/tmp/parallax/user-data",
                        isDirectory: true
                    )
                ),
                ImportedLaunchIsolationPath(
                    role: .codexHome,
                    authority: .external,
                    canonicalURL: URL(
                        fileURLWithPath: "/tmp/parallax/codex-home",
                        isDirectory: true
                    )
                ),
            ]
        )
    }

    private func profile(
        for source: ImportedLaunchTrustSource
    ) -> LaunchProfile {
        LaunchProfile(
            id: source.profileID,
            storageID: source.profileStorageID,
            name: source.profileName,
            argumentsText: source.argumentsText,
            environmentText: source.environmentText,
            isolationOwnership: source.isolationOwnership,
            childEnvironmentPolicy: source.childEnvironmentPolicy,
            sensitiveEnvironmentKeys: source.sensitiveEnvironmentKeys
        )
    }

    private func fixedUUID(_ value: String) -> UUID {
        // Test constants are compile-time controlled; a decoding fallback keeps
        // the helper free of force unwraps.
        UUID(uuidString: value) ?? UUID()
    }
}

private extension ImportedLaunchTrustSource {
    func replacing(
        applicationID: UUID? = nil,
        applicationStorageID: UUID? = nil,
        canonicalApplicationURL: URL? = nil,
        configuredBaseRoot: String? = nil,
        isolationOwnership: ProfileIsolationOwnership? = nil,
        expectedBundleIdentifier: String?? = nil,
        verifiedBundleIdentifier: String?? = nil,
        profileStorageID: UUID? = nil,
        argumentsText: String? = nil,
        environmentText: String? = nil,
        childEnvironmentPolicy: ChildEnvironmentPolicy? = nil,
        sensitiveEnvironmentKeys: [String]? = nil,
        isolationPaths: [ImportedLaunchIsolationPath]? = nil
    ) -> ImportedLaunchTrustSource {
        ImportedLaunchTrustSource(
            applicationID: applicationID ?? self.applicationID,
            applicationStorageID:
                applicationStorageID ?? self.applicationStorageID,
            applicationDisplayName: applicationDisplayName,
            canonicalApplicationURL:
                canonicalApplicationURL ?? self.canonicalApplicationURL,
            expectedBundleIdentifier:
                expectedBundleIdentifier ?? self.expectedBundleIdentifier,
            verifiedBundleIdentifier:
                verifiedBundleIdentifier ?? self.verifiedBundleIdentifier,
            profileID: profileID,
            profileStorageID: profileStorageID ?? self.profileStorageID,
            profileName: profileName,
            configuredBaseRoot: configuredBaseRoot ?? self.configuredBaseRoot,
            argumentsText: argumentsText ?? self.argumentsText,
            environmentText: environmentText ?? self.environmentText,
            isolationOwnership:
                isolationOwnership ?? self.isolationOwnership,
            childEnvironmentPolicy:
                childEnvironmentPolicy ?? self.childEnvironmentPolicy,
            sensitiveEnvironmentKeys:
                sensitiveEnvironmentKeys ?? self.sensitiveEnvironmentKeys,
            isolationPaths: isolationPaths ?? self.isolationPaths
        )
    }
}
