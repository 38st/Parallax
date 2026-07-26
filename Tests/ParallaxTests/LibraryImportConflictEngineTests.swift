import Foundation
import XCTest
@testable import Parallax

final class LibraryImportConflictEngineTests: XCTestCase {
    func testTrustAndLaunchHistoryDoNotCreateConfigurationConflict()
        throws
    {
        let profileID = UUID()
        let profileStorageID = UUID()
        let existingProfile = LaunchProfile(
            id: profileID,
            storageID: profileStorageID,
            name: "Work",
            launchConfigurationTrust: .local,
            lastLaunchedAt: Date(timeIntervalSince1970: 1)
        )
        let importedProfile = LaunchProfile(
            id: profileID,
            storageID: profileStorageID,
            name: "Work",
            launchConfigurationTrust: .importedPendingReview,
            lastLaunchedAt: nil
        )
        let applicationID = UUID()
        let applicationStorageID = UUID()
        let existing = application(
            id: applicationID,
            storageID: applicationStorageID,
            name: "Browser",
            path: "/Applications/Browser.app",
            profiles: [existingProfile]
        )
        let imported = application(
            id: applicationID,
            storageID: applicationStorageID,
            name: "Browser",
            path: "/Applications/Browser.app",
            profiles: [importedProfile]
        )

        let result = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.applications, [existing.application])
    }

    func testSameBundleAtDifferentCanonicalPathIsRelocationConflict() throws {
        let existing = application(
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Applications/Browser.app"
        )
        let imported = application(
            name: "Browser Copy",
            bundle: "com.example.browser",
            path: "/Volumes/Tools/Browser.app"
        )

        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )

        XCTAssertNil(preview.applications)
        XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertTrue(
            preview.conflicts[0].reasons.contains(
                .bundleIdentifierRelocation
            )
        )
    }

    func testUseImportedAdoptsEveryApplicationFieldWithoutDroppingProfiles() throws {
        let existingProfile = profile(name: "Existing")
        let importedProfile = profile(name: "Imported")
        let identity = UUID()
        let storageID = UUID()
        let existing = application(
            id: identity,
            storageID: storageID,
            name: "Old Name",
            bundle: "com.example.old",
            path: "/Applications/Old.app",
            preset: .chrome,
            baseRoot: "/Managed/Old",
            profiles: [existingProfile]
        )
        let imported = application(
            id: identity,
            storageID: storageID,
            name: "New Name",
            bundle: "com.example.new",
            path: "/Applications/New.app",
            preset: .codex,
            baseRoot: "/Managed/New",
            profiles: [importedProfile]
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(preview.conflicts.first)
        XCTAssertTrue(
            conflict.reasons.contains(
                .applicationFields(
                    [
                        .displayName,
                        .bundleIdentifier,
                        .applicationPath,
                        .preset,
                        .baseStoragePath,
                    ]
                )
            )
        )

        let result = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: [
                conflict.id: .useImported(applicationID: identity)
            ]
        )
        let merged = try XCTUnwrap(result.applications?.first)

        XCTAssertEqual(merged.id, identity)
        XCTAssertEqual(merged.storageID, storageID)
        XCTAssertEqual(merged.displayName, "New Name")
        XCTAssertEqual(merged.bundleIdentifier, "com.example.new")
        XCTAssertEqual(merged.appPath, "/Applications/New.app")
        XCTAssertEqual(merged.preset, .codex)
        XCTAssertEqual(merged.baseStoragePath, "/Managed/New")
        XCTAssertEqual(
            Set(merged.profiles.map(\.id)),
            [existingProfile.id, importedProfile.id]
        )
    }

    func testKeepExistingPreservesAllApplicationFieldsAndMergesUniqueProfile() throws {
        let importedProfile = profile(name: "Imported")
        let existing = application(
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Applications/Browser.app",
            preset: .brave,
            baseRoot: "/Managed/Existing"
        )
        let imported = application(
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Volumes/Other/Browser.app",
            preset: .edge,
            baseRoot: "/Managed/Imported",
            profiles: [importedProfile]
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(preview.conflicts.first)

        let result = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: [
                conflict.id: .keepExisting(
                    applicationID: existing.application.id
                )
            ]
        )
        let merged = try XCTUnwrap(result.applications?.first)

        XCTAssertEqual(merged.appPath, existing.application.appPath)
        XCTAssertEqual(merged.preset, existing.application.preset)
        XCTAssertEqual(
            merged.baseStoragePath,
            existing.application.baseStoragePath
        )
        XCTAssertEqual(merged.profiles.map(\.id), [importedProfile.id])
    }

    func testKeepBothApplicationRequiresFreshNestedIdentitiesAndRename() throws {
        let incomingProfiles = [
            profile(name: "One"),
            profile(name: "Two"),
        ]
        let existing = application(
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Applications/Browser.app"
        )
        let imported = application(
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Applications/Browser.app",
            profiles: incomingProfiles
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(preview.conflicts.first)
        let freshProfiles = Dictionary(
            uniqueKeysWithValues: incomingProfiles.map {
                (
                    $0.id,
                    LibraryImportFreshProfileIdentity(
                        id: UUID(),
                        storageID: UUID()
                    )
                )
            }
        )
        let fresh = LibraryImportFreshApplicationIdentity(
            id: UUID(),
            storageID: UUID(),
            profileIdentities: freshProfiles
        )

        let result = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: [
                conflict.id: .keepBoth(
                    .application(
                        renamedTo: "Browser (Imported)",
                        identity: fresh
                    )
                )
            ]
        )
        let applications = try XCTUnwrap(result.applications)
        let duplicated = try XCTUnwrap(
            applications.first { $0.id == fresh.id }
        )

        XCTAssertEqual(duplicated.displayName, "Browser (Imported)")
        XCTAssertEqual(duplicated.storageID, fresh.storageID)
        XCTAssertEqual(
            Set(duplicated.profiles.map(\.id)),
            Set(freshProfiles.values.map(\.id))
        )
        XCTAssertEqual(
            Set(duplicated.profiles.map(\.storageID)),
            Set(freshProfiles.values.map(\.storageID))
        )
        XCTAssertTrue(
            Set(duplicated.profiles.map(\.id))
                .isDisjoint(with: Set(incomingProfiles.map(\.id)))
        )
    }

    func testLaterDuplicateProfileNameInBatchUsesUpdatedComparisonSet() throws {
        let applicationID = UUID()
        let storageID = UUID()
        let existing = application(
            id: applicationID,
            storageID: storageID,
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Applications/Browser.app"
        )
        let first = profile(
            name: "Wörk",
            arguments: "--first"
        )
        let second = profile(
            name: "WORK",
            arguments: "--second"
        )
        let imported = application(
            id: applicationID,
            storageID: storageID,
            name: "Browser",
            bundle: "com.example.browser",
            path: "/Applications/Browser.app",
            profiles: [first, second]
        )

        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(
            preview.conflicts.first { $0.scope == .profile }
        )

        XCTAssertNil(preview.applications)
        XCTAssertEqual(conflict.importedProfileID, second.id)
        XCTAssertTrue(
            conflict.reasons.contains(.normalizedProfileName)
        )
        XCTAssertTrue(
            conflict.reasons.contains(
                .profileFields([.name, .arguments])
            )
        )
    }

    func testUseImportedProfilePreservesIdentityAndUpdatesCompleteContent() throws {
        let existingProfile = profile(
            name: "Work",
            arguments: "--old",
            environment: "OLD=1",
            notes: "old"
        )
        let incomingProfile = LaunchProfile(
            id: existingProfile.id,
            storageID: existingProfile.storageID,
            name: "Work Renamed",
            argumentsText: "--new",
            environmentText: "NEW=1",
            notes: "new",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            ),
            childEnvironmentPolicy: .inheritProcessEnvironment,
            sensitiveEnvironmentKeys: ["NEW"],
            launchConfigurationTrust: .importedPendingReview,
            lastLaunchedAt: Date(timeIntervalSince1970: 42)
        )
        let appID = UUID()
        let appStorageID = UUID()
        let existing = application(
            id: appID,
            storageID: appStorageID,
            name: "Browser",
            path: "/Applications/Browser.app",
            profiles: [existingProfile]
        )
        let imported = application(
            id: appID,
            storageID: appStorageID,
            name: "Browser",
            path: "/Applications/Browser.app",
            profiles: [incomingProfile]
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(
            preview.conflicts.first { $0.scope == .profile }
        )

        let result = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: [
                conflict.id: .useImported(
                    applicationID: appID,
                    profileID: existingProfile.id
                )
            ]
        )
        let merged = try XCTUnwrap(
            result.applications?.first?.profiles.first
        )

        XCTAssertEqual(merged.id, existingProfile.id)
        XCTAssertEqual(merged.storageID, existingProfile.storageID)
        XCTAssertEqual(merged.name, incomingProfile.name)
        XCTAssertEqual(merged.argumentsText, incomingProfile.argumentsText)
        XCTAssertEqual(
            merged.environmentText,
            incomingProfile.environmentText
        )
        XCTAssertEqual(merged.notes, incomingProfile.notes)
        XCTAssertEqual(
            merged.isolationOwnership,
            incomingProfile.isolationOwnership
        )
        XCTAssertEqual(
            merged.childEnvironmentPolicy,
            incomingProfile.childEnvironmentPolicy
        )
        XCTAssertEqual(
            merged.sensitiveEnvironmentKeys,
            incomingProfile.sensitiveEnvironmentKeys
        )
        XCTAssertEqual(
            merged.launchConfigurationTrust,
            incomingProfile.launchConfigurationTrust
        )
        XCTAssertEqual(
            merged.lastLaunchedAt,
            incomingProfile.lastLaunchedAt
        )
    }

    func testSkipAndUnresolvedResultsNeverExposePartialApplications() throws {
        let existing = application(
            name: "Browser",
            path: "/Applications/Browser.app"
        )
        let imported = application(
            name: "browser",
            path: "/Applications/Other.app"
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(preview.conflicts.first)
        XCTAssertNil(preview.applications)

        let skipped = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: [conflict.id: .skip]
        )
        XCTAssertEqual(
            skipped.applications,
            [existing.application]
        )
    }

    func testResolutionIsDeterministicForIdenticalInputsAndDecisions() throws {
        let existing = application(
            name: "Browser",
            path: "/Applications/Browser.app"
        )
        let imported = application(
            name: "browser",
            path: "/Applications/Other.app"
        )
        let preview = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported]
        )
        let conflict = try XCTUnwrap(preview.conflicts.first)
        let decisions = [
            conflict.id: LibraryImportConflictResolution.keepExisting(
                applicationID: existing.application.id
            )
        ]

        let first = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: decisions
        )
        let second = try LibraryImportConflictEngine.resolve(
            existing: [existing],
            imported: [imported],
            resolutions: decisions
        )

        XCTAssertEqual(first, second)
    }

    private func application(
        id: UUID = UUID(),
        storageID: UUID = UUID(),
        name: String,
        bundle: String? = nil,
        path: String,
        preset: AppPreset = .automatic,
        baseRoot: String? = nil,
        profiles: [LaunchProfile] = []
    ) -> LibraryImportApplication {
        LibraryImportApplication(
            application: ManagedApplication(
                id: id,
                storageID: storageID,
                displayName: name,
                bundleIdentifier: bundle,
                appPath: path,
                preset: preset,
                baseStoragePath: baseRoot,
                profiles: profiles
            ),
            canonicalApplicationPath: path
        )
    }

    private func profile(
        name: String,
        arguments: String = "",
        environment: String = "",
        notes: String = ""
    ) -> LaunchProfile {
        LaunchProfile(
            name: name,
            argumentsText: arguments,
            environmentText: environment,
            notes: notes
        )
    }
}
