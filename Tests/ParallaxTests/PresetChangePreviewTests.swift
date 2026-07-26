import Foundation
import XCTest
@testable import Parallax

final class PresetChangePreviewTests: XCTestCase {
    private let service = PresetChangePreviewService()

    func testPresetMetadataApplicationNeverMutatesProfilesOrOtherMetadata()
        throws
    {
        let profile = LaunchProfile(
            name: "Explicit",
            argumentsText: "--user-data-dir='/External/User Data' --flag",
            environmentText: "CODEX_HOME=/External/Codex\nLABEL=value",
            notes: "Keep notes",
            isolationOwnership: .explicit
        )
        let application = makeApplication(
            preset: .codex,
            profiles: [profile]
        )
        let preview = try service.preview(
            application: application,
            targetPreset: .chrome,
            generatedPaths: [paths(for: profile)]
        )
        var metadataEdited = application
        metadataEdited.displayName = "Renamed Metadata"
        metadataEdited.bundleIdentifier = "example.renamed"

        let result = try service.applyingPresetMetadata(
            preview,
            to: metadataEdited
        )

        XCTAssertEqual(result.preset, .chrome)
        XCTAssertEqual(result.displayName, "Renamed Metadata")
        XCTAssertEqual(result.bundleIdentifier, "example.renamed")
        XCTAssertEqual(result.profiles, [profile])
    }

    func testExplicitIsolationSurvivesPresetRemovalAndAuthorizedRefresh()
        throws
    {
        let profile = LaunchProfile(
            name: "External",
            argumentsText:
                "--user-data-dir '/Volumes/External User Data' --flag",
            environmentText:
                "unset CODEX_HOME\nLABEL=unchanged",
            isolationOwnership: .explicit
        )
        let application = makeApplication(
            preset: .codex,
            profiles: [profile]
        )
        let preview = try service.preview(
            application: application,
            targetPreset: .custom,
            generatedPaths: []
        )

        XCTAssertEqual(
            preview.changes.map(\.kind),
            [
                .userDataDirectory,
                .codexHome,
            ]
        )
        XCTAssertEqual(
            preview.changes.map(\.disposition),
            [.retained, .retained]
        )
        XCTAssertEqual(
            preview.changes.map(\.resultingOwnership),
            [.explicit, .explicit]
        )

        let authorization = service.authorizeRefresh(
            preview,
            acknowledging: .applyListedGeneratedValueChanges
        )
        let result = try service.applyingAuthorizedRefresh(
            preview,
            authorization: authorization,
            to: application
        )

        XCTAssertEqual(result.profiles, [profile])
        XCTAssertEqual(result.preset, .custom)
    }

    func testGeneratedValuesPreviewRetainedAndRemovedWhenLeavingCodex()
        throws
    {
        let profile = LaunchProfile(
            name: "Generated",
            argumentsText:
                "--flag --user-data-dir=/Managed/Profile/UserData",
            environmentText:
                "LABEL=unchanged\nCODEX_HOME=/Managed/Profile/CodexHome",
            notes: "Untouched",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
        let application = makeApplication(
            preset: .codex,
            profiles: [profile]
        )
        let preview = try service.preview(
            application: application,
            targetPreset: .chrome,
            generatedPaths: [
                PresetGeneratedPaths(
                    profileID: profile.id,
                    profileStorageID: profile.storageID,
                    userDataDirectory: "/Managed/Profile/UserData",
                    codexHome: "/Managed/Profile/CodexHome"
                ),
            ]
        )

        XCTAssertEqual(
            preview.changes.map(\.kind),
            [.userDataDirectory, .codexHome]
        )
        XCTAssertEqual(
            preview.changes.map(\.disposition),
            [.retained, .removed]
        )

        let authorization = service.authorizeRefresh(
            preview,
            acknowledging: .applyListedGeneratedValueChanges
        )
        let result = try service.applyingAuthorizedRefresh(
            preview,
            authorization: authorization,
            to: application
        )
        let refreshed = try XCTUnwrap(result.profiles.first)

        XCTAssertEqual(
            UserDataDirectoryOptionResolver.resolve(
                in: LaunchArgumentParser.parse(
                    refreshed.argumentsText
                ).tokens
            ).resolvedValue,
            "/Managed/Profile/UserData"
        )
        XCTAssertNil(
            LaunchEnvironmentParser.parse(
                refreshed.environmentText
            ).effectiveOperations["CODEX_HOME"]
        )
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(
                refreshed.environmentText
            ).effectiveValues["LABEL"],
            "unchanged"
        )
        XCTAssertEqual(
            refreshed.isolationOwnership,
            ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            )
        )
        XCTAssertEqual(refreshed.notes, "Untouched")
    }

    func testCodexPreviewAddsMissingAndChangesStaleGeneratedValues()
        throws
    {
        let profile = LaunchProfile(
            name: "Generated",
            argumentsText: "--user-data-dir=/Old/UserData --flag",
            environmentText: "LABEL=value",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            )
        )
        let application = makeApplication(
            preset: .chrome,
            profiles: [profile]
        )
        let generated = PresetGeneratedPaths(
            profileID: profile.id,
            profileStorageID: profile.storageID,
            userDataDirectory: "/New/UserData",
            codexHome: "/New/CodexHome"
        )
        let preview = try service.preview(
            application: application,
            targetPreset: .codex,
            generatedPaths: [generated]
        )

        XCTAssertEqual(
            preview.changes.map(\.kind),
            [.userDataDirectory, .codexHome]
        )
        XCTAssertEqual(
            preview.changes.map(\.disposition),
            [.changed, .added]
        )

        let authorization = service.authorizeRefresh(
            preview,
            acknowledging: .applyListedGeneratedValueChanges
        )
        let result = try service.applyingAuthorizedRefresh(
            preview,
            authorization: authorization,
            to: application
        )
        let refreshed = try XCTUnwrap(result.profiles.first)

        XCTAssertEqual(
            UserDataDirectoryOptionResolver.resolve(
                in: LaunchArgumentParser.parse(
                    refreshed.argumentsText
                ).tokens
            ).resolvedValue,
            generated.userDataDirectory
        )
        XCTAssertEqual(
            LaunchEnvironmentParser.parse(
                refreshed.environmentText
            ).effectiveValues["CODEX_HOME"],
            generated.codexHome
        )
        XCTAssertEqual(
            refreshed.isolationOwnership,
            ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
    }

    func testDedicatedRefreshIsAuthorizationBoundAndRejectsStaleProfiles()
        throws
    {
        let profile = LaunchProfile(
            name: "Generated",
            argumentsText: "--user-data-dir=/Old/UserData",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            )
        )
        let application = makeApplication(
            preset: .chrome,
            profiles: [profile]
        )
        let preview = try service.preview(
            application: application,
            targetPreset: .chrome,
            generatedPaths: [
                PresetGeneratedPaths(
                    profileID: profile.id,
                    profileStorageID: profile.storageID,
                    userDataDirectory: "/New/UserData",
                    codexHome: "/Unused/CodexHome"
                ),
            ]
        )
        let otherPreview = try service.preview(
            application: application,
            targetPreset: .custom,
            generatedPaths: []
        )
        let wrongAuthorization = service.authorizeRefresh(
            otherPreview,
            acknowledging: .applyListedGeneratedValueChanges
        )

        XCTAssertThrowsError(
            try service.applyingAuthorizedRefresh(
                preview,
                authorization: wrongAuthorization,
                to: application
            )
        ) { error in
            XCTAssertEqual(
                error as? PresetChangePreviewError,
                .invalidRefreshAuthorization
            )
        }

        let authorization = service.authorizeRefresh(
            preview,
            acknowledging: .applyListedGeneratedValueChanges
        )
        var stale = application
        stale.profiles[0].argumentsText += " --concurrent-edit"

        XCTAssertThrowsError(
            try service.applyingAuthorizedRefresh(
                preview,
                authorization: authorization,
                to: stale
            )
        ) { error in
            XCTAssertEqual(
                error as? PresetChangePreviewError,
                .stalePreview
            )
        }
    }

    func testRefreshPreservesMetadataEditsMadeAfterPreview() throws {
        let profile = LaunchProfile(
            name: "Generated",
            argumentsText: "--user-data-dir=/Old/UserData",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            )
        )
        let application = makeApplication(
            preset: .chrome,
            profiles: [profile]
        )
        let preview = try service.preview(
            application: application,
            targetPreset: .chrome,
            generatedPaths: [paths(for: profile)]
        )
        let authorization = service.authorizeRefresh(
            preview,
            acknowledging: .applyListedGeneratedValueChanges
        )
        var metadataEdited = application
        metadataEdited.displayName = "Concurrent Rename"
        metadataEdited.appPath = "/Applications/Renamed.app"

        let result = try service.applyingAuthorizedRefresh(
            preview,
            authorization: authorization,
            to: metadataEdited
        )

        XCTAssertEqual(result.displayName, "Concurrent Rename")
        XCTAssertEqual(result.appPath, "/Applications/Renamed.app")
        XCTAssertEqual(
            UserDataDirectoryOptionResolver.resolve(
                in: LaunchArgumentParser.parse(
                    result.profiles[0].argumentsText
                ).tokens
            ).resolvedValue,
            "/Managed/UserData"
        )
    }

    func testMalformedGeneratedArgumentsBlockLossyRefresh() throws {
        let profile = LaunchProfile(
            name: "Malformed",
            argumentsText:
                "--user-data-dir=/Old/UserData 'unterminated",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            )
        )
        let application = makeApplication(
            preset: .chrome,
            profiles: [profile]
        )

        XCTAssertThrowsError(
            try service.preview(
                application: application,
                targetPreset: .custom,
                generatedPaths: []
            )
        ) { error in
            XCTAssertEqual(
                error as? PresetChangePreviewError,
                .invalidGeneratedArguments(profileID: profile.id)
            )
        }
    }

    private func makeApplication(
        preset: AppPreset,
        profiles: [LaunchProfile]
    ) -> ManagedApplication {
        ManagedApplication(
            displayName: "Preset Test",
            bundleIdentifier: "example.preset-test",
            appPath: "/Applications/Preset Test.app",
            preset: preset,
            baseStoragePath: "/Managed",
            profiles: profiles
        )
    }

    private func paths(for profile: LaunchProfile) -> PresetGeneratedPaths {
        PresetGeneratedPaths(
            profileID: profile.id,
            profileStorageID: profile.storageID,
            userDataDirectory: "/Managed/UserData",
            codexHome: "/Managed/CodexHome"
        )
    }
}
