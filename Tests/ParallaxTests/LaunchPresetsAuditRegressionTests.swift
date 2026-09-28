import XCTest
@testable import Parallax

final class LaunchPresetsAuditRegressionTests: XCTestCase {
    func testFirefoxBundleIdentifiersSelectFirefoxPreset() {
        for bundle in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"] {
            XCTAssertEqual(AppPreset.detected(displayName: "Browser", bundleIdentifier: bundle).rawValue, "firefox")
        }
    }

    func testCodeFamilyBundleIdentifiersSelectCodePreset() {
        for bundle in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"] {
            XCTAssertEqual(AppPreset.detected(displayName: "Editor", bundleIdentifier: bundle).rawValue, "visualStudioCode")
        }
    }

    func testAdditionalChromiumBundleIdentifiersAndArcFallback() {
        for bundle in ["com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium"] {
            XCTAssertEqual(AppPreset.detected(displayName: "Browser", bundleIdentifier: bundle), .chromium)
        }
        XCTAssertEqual(AppPreset.detected(displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser"), .custom)
        XCTAssertEqual(AppPreset.detected(displayName: "Chromium", bundleIdentifier: "company.thebrowser.Browser"), .custom)
    }
}

final class PresetCompilationAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory
    private var fixture: ValidApplicationBundleFixture?
    private let applicationID = UUID()
    private let applicationStorageID = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fixture = try ValidApplicationBundleFixture.create(in: root)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func source(_ preset: AppPreset, arguments: String = "", environment: String = "",
                        recommended: Bool = false, ownershipOverride: ProfileIsolationOwnership? = nil, peers: [LaunchPeerProfileSource] = []) throws -> LaunchConfigurationSource {
        let app = try XCTUnwrap(fixture)
        let profileID = UUID()
        let storageID = UUID()
        let base = root.appendingPathComponent("data").path
        var text = arguments
        var ownership = ProfileIsolationOwnership.explicit
        if recommended {
            let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
                configuredBaseRoot: base, applicationStorageID: applicationStorageID, profileStorageID: storageID)
            if preset.supportsUserDataDir {
                text = ShellWordsParser.quote("--user-data-dir=\(paths.userData.url.path)") + " " + text
                ownership.userData = .generated
            }
            for folder in PresetIsolationFolder.allCases where folder.applies(to: preset) {
                text = try folder.setting(folder.managedPath(in: paths).url.path, in: text)
                ownership[keyPath: folder.ownershipKeyPath] = .generated
            }
        }
        return LaunchConfigurationSource(
            requestID: UUID(), applicationID: applicationID, applicationStorageID: applicationStorageID,
            profileID: profileID, profileStorageID: storageID, configurationRevision: 1,
            applicationURL: app.url, expectedBundleIdentifier: app.bundleIdentifier,
            configuredBaseRoot: base, argumentsText: text, environmentText: environment, isolationOwnership: ownershipOverride ?? ownership,
            childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [], preset: preset, peerProfiles: peers
        )
    }

    func testExistingCustomEraSpacesDoNotGainIsolationOptions() async throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let prepared = try await LaunchConfigurationCompiler(processEnvironment: [:]).prepare(
                source(preset, arguments: "--new-window"))
            XCTAssertEqual(prepared.arguments, ["--new-window"])
            XCTAssertTrue(prepared.isolation.managedVerificationPaths.isEmpty)
        }
    }

    func testFirefoxOtherProfileSelectionsNeverGainManagedProfile() async throws {
        for arguments in ["-P work", "-P", "-p x", "--ProfileManager", "-CreateProfile", "--CREATEPROFILE=name", "--p=work"] {
            let prepared = try await LaunchConfigurationCompiler(processEnvironment: [:]).prepare(
                source(.firefox, arguments: arguments))
            XCTAssertEqual(prepared.arguments, LaunchArgumentParser.parse(arguments).words)
            XCTAssertTrue(prepared.isolation.managedVerificationPaths.isEmpty)
        }
    }

    func testFirefoxEnvironmentSelectionAndGeneratedConflict() async throws {
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let environment = "XRE_PROFILE_PATH=\(root.appendingPathComponent("named").path)"
        let external = try await compiler.prepare(source(.firefox, environment: environment))
        XCTAssertTrue(external.arguments.isEmpty)
        XCTAssertTrue(external.isolation.managedVerificationPaths.isEmpty)
        for (arguments, environment) in [("-P work", ""), ("", environment)] {
            let analysis = await compiler.analyze(try source(.firefox, arguments: arguments,
                                                           environment: environment, recommended: true))
            let diagnostic = try XCTUnwrap(analysis.diagnostics.first { $0.code == .conflictingFirefoxProfileSelection })
            XCTAssertFalse(diagnostic.isOverridable)
            XCTAssertNotNil(diagnostic.sourceRange)
            XCTAssertNil(analysis.isolation.presetFolders[.firefoxProfile])
        }
    }

    func testPresetOptionDiagnosticsHaveSpecificMessagesAndSourceRanges() async throws {
        for (preset, arguments) in [(AppPreset.firefox, "--profile"), (.firefox, "-profile /one --profile /two"),
                                    (.visualStudioCode, "--extensions-dir")] {
            let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(try source(preset, arguments: arguments))
            let diagnostic = try XCTUnwrap(analysis.diagnostics.first { $0.sourceRange != nil })
            XCTAssertTrue(diagnostic.message.contains("only once"))
            XCTAssertFalse(diagnostic.isOverridable)
        }
    }

    func testFirefoxPreparesFreshManagedFolderAndFlagsBeforeTerminator() async throws {
        let source = try source(.firefox, arguments: "-- https://example.invalid", recommended: true)
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(configuredBaseRoot: source.configuredBaseRoot,
            applicationStorageID: source.applicationStorageID, profileStorageID: source.profileStorageID)
        let analysis = await compiler.analyze(source)
        XCTAssertEqual(analysis.isolation.presetFolders[.firefoxProfile], .managed(paths.firefoxProfile.url))
        let prepared = try await compiler.prepare(source)
        XCTAssertEqual(prepared.arguments, ["-profile", paths.firefoxProfile.url.path, "-no-remote", "--", "https://example.invalid"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.firefoxProfile.url.path))
        XCTAssertEqual(paths.firefoxProfile.url.lastPathComponent, "FirefoxProfile")
        XCTAssertTrue(paths.firefoxProfile.url.path.hasPrefix(paths.profileRoot.url.path + "/"))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: paths.firefoxProfile.url).posixPermissions, 0o700)
        XCTAssertEqual(prepared.isolation.managedVerificationPaths, [.managed(paths.firefoxProfile.url)])
    }

    func testFirefoxExplicitSpellingsRemainUserOwnedAndUncreated() async throws {
        let external = root.appendingPathComponent("external profile")
        for option in ["-profile", "--profile", "--PROFILE", "-Profile"] {
            for arguments in ["\(option) \(ShellWordsParser.quote(external.path))", ShellWordsParser.quote("\(option)=\(external.path)")] {
                let source = try source(.firefox, arguments: arguments)
                let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
                let analysis = await compiler.analyze(source)
                XCTAssertEqual(analysis.isolation.presetFolders[.firefoxProfile]?.isManaged, false)
                let prepared = try await compiler.prepare(source)
                XCTAssertEqual(prepared.arguments, ["-profile", external.path])
                XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
                XCTAssertTrue(prepared.isolation.managedVerificationPaths.isEmpty)
            }
        }
    }

    func testFirefoxStartupProfileFlagAfterTerminatorIsStillUserOwned() async throws {
        let external = root.appendingPathComponent("external")
        let source = try source(.firefox, arguments: "-- --PROFILE=\(external.path)")
        let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
        XCTAssertEqual(analysis.isolation.presetFolders[.firefoxProfile]?.url.path, external.path)
        XCTAssertEqual(analysis.isolation.presetFolders[.firefoxProfile]?.isManaged, false)
        XCTAssertEqual(analysis.preview.arguments, ["-profile", external.path, "--"])
    }

    func testCodeFamilyPreparesBothManagedFoldersAndPreservesExplicitExtensions() async throws {
        let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
        let source = try source(.visualStudioCode, recommended: true)
        let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(configuredBaseRoot: source.configuredBaseRoot,
            applicationStorageID: source.applicationStorageID, profileStorageID: source.profileStorageID)
        let prepared = try await compiler.prepare(source)
        XCTAssertEqual(prepared.arguments, ["--user-data-dir=\(paths.userData.url.path)", "--extensions-dir=\(paths.extensions.url.path)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.extensions.url.path))
        XCTAssertEqual(paths.extensions.url.lastPathComponent, "Extensions")
        XCTAssertTrue(paths.extensions.url.path.hasPrefix(paths.profileRoot.url.path + "/"))
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: paths.extensions.url).posixPermissions, 0o700)
        let external = root.appendingPathComponent("external extensions")
        let custom = try self.source(.visualStudioCode, arguments: "--extensions-dir \(ShellWordsParser.quote(external.path))")
        let customPrepared = try await compiler.prepare(custom)
        XCTAssertTrue(customPrepared.arguments.contains("--extensions-dir=\(external.path)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertFalse(customPrepared.isolation.managedVerificationPaths.contains { $0.url == external })
    }

    func testInvalidAndDuplicateIsolationOptionsBlockWithoutOverride() async throws {
        for (preset, arguments) in [(AppPreset.firefox, "--profile"), (.firefox, "-profile= "),
            (.firefox, "-profile /one --profile /two"), (.firefox, "-profile relative"),
            (.visualStudioCode, "--extensions-dir"), (.visualStudioCode, "--extensions-dir=/one --extensions-dir=/two")] {
            let source = try source(preset, arguments: arguments)
            let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
            XCTAssertTrue(analysis.hasBlockingDiagnostics, arguments)
            XCTAssertTrue(analysis.diagnostics.contains { $0.severity == .error && !$0.isOverridable }, arguments)
        }
    }

    func testPeerAliasesCollideForFirefoxAndExtensions() async throws {
        let shared = root.appendingPathComponent("shared")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        for (preset, option) in [(AppPreset.firefox, "-profile"), (.visualStudioCode, "--extensions-dir")] {
            let peer = LaunchPeerProfileSource(profileID: UUID(), profileStorageID: UUID(),
                argumentsText: "\(option) \(ShellWordsParser.quote(alias.path))", environmentText: "", isolationOwnership: .explicit)
            let source = try source(preset, arguments: "\(option) \(ShellWordsParser.quote(shared.path))", peers: [peer])
            let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
            XCTAssertTrue(analysis.diagnostics.contains { $0.code == .profileHealth(.canonicalPathCollision) })
        }
    }

    func testNewIsolationFoldersAreCheckedForWritability() async throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let source = try source(preset, recommended: true)
            let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
                configuredBaseRoot: source.configuredBaseRoot,
                applicationStorageID: source.applicationStorageID, profileStorageID: source.profileStorageID)
            let folder = preset == .firefox ? paths.firefoxProfile.url : paths.extensions.url
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let canonicalFolder = try LocalFileSystem().canonicalURL(for: folder)
            let analysis = await LaunchConfigurationCompiler(
                writeAccess: PresetDeniedWriteAccess(denied: canonicalFolder), processEnvironment: [:]).analyze(source)
            XCTAssertTrue(analysis.diagnostics.contains {
                $0.code == .profileHealth(.targetNotWritable) && $0.path == canonicalFolder.path
            }, "\(preset): \(analysis.diagnostics)")
        }
    }

    func testDuplicateResetRemovesOverridesButKeepsPositionalArguments() async throws {
        for (preset, text) in [(AppPreset.firefox, "--profile /external -- file"), (.visualStudioCode, "--extensions-dir=/external -- file")] {
            let reset = try PresetIsolationFolder.removingOverrides(from: text, preset: preset)
            XCTAssertEqual(LaunchArgumentParser.parse(reset).words, ["--", "file"])
            let first = try source(preset, arguments: reset, recommended: true)
            let second = try source(preset, arguments: reset, recommended: true)
            let compiler = LaunchConfigurationCompiler(processEnvironment: [:])
            let original = await compiler.analyze(first)
            let duplicate = await compiler.analyze(second)
            let folder: PresetIsolationFolder = preset == .firefox ? .firefoxProfile : .extensions
            let originalPath = try XCTUnwrap(original.isolation.presetFolders[folder])
            let duplicatePath = try XCTUnwrap(duplicate.isolation.presetFolders[folder])
            XCTAssertTrue(originalPath.isManaged)
            XCTAssertTrue(duplicatePath.isManaged)
            XCTAssertNotEqual(originalPath.url.path, duplicatePath.url.path)
            XCTAssertTrue(duplicatePath.url.path.contains(second.profileStorageID.uuidString.lowercased()))
            XCTAssertEqual(Array(duplicate.preview.arguments.suffix(2)), ["--", "file"])
            XCTAssertFalse(duplicate.preview.arguments.contains("/external"))
        }
    }

    func testDuplicateResetPreservesOtherTextAndRejectsMalformedArguments() throws {
        let text = "'🦊'  --profile '/external path'  -- \"a b\""
        XCTAssertEqual(try PresetIsolationFolder.removingOverrides(from: text, preset: .firefox),
                       "'🦊'    -- \"a b\"")
        XCTAssertThrowsError(try PresetIsolationFolder.removingOverrides(
            from: "--profile '/external", preset: .firefox))
    }

    func testManagedPresetFolderSymlinkIsBlockedDuringAnalysis() async throws {
        let source = try source(.firefox, recommended: true)
        let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
            configuredBaseRoot: source.configuredBaseRoot,
            applicationStorageID: source.applicationStorageID, profileStorageID: source.profileStorageID)
        try FileManager.default.createDirectory(at: paths.profileRoot.url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.firefoxProfile.url, withDestinationURL: outside)
        let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .profileHealth(.managedPathInvalid) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    @MainActor
    func testImportedReviewIncludesFirefoxAndExtensionsOwnership() async throws {
        let settings = AppSettings()
        settings.defaultBaseStoragePath = root.path
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: root.appendingPathComponent("library")),
                                 profileActivityRegistry: ProfileActivityRegistry(), settings: settings)
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let source = try source(preset, recommended: true)
            let profile = LaunchProfile(id: source.profileID, storageID: source.profileStorageID, name: "Fixture")
            let app = ManagedApplication(id: source.applicationID, storageID: source.applicationStorageID,
                displayName: "Fixture", bundleIdentifier: source.expectedBundleIdentifier,
                appPath: source.applicationURL.path, preset: preset,
                baseStoragePath: source.configuredBaseRoot, profiles: [profile])
            let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
            let review = ImportedLaunchTrust().review(for: store.importedLaunchTrustSource(
                application: app, profile: profile, analysis: analysis, source: source))
            let role: ImportedLaunchIsolationRole = preset == .firefox ? .firefoxProfile : .extensions
            XCTAssertEqual(review.isolationPaths.first { $0.role == role }?.authority, .managed)
        }
    }

    func testExplicitOwnFolderIsManagedAndHealthDoesNotChangeProviderPermissions() async throws {
        for preset in [AppPreset.firefox, .visualStudioCode] {
            let source = try source(preset, recommended: true, ownershipOverride: .explicit)
            let paths = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
                configuredBaseRoot: source.configuredBaseRoot, applicationStorageID: source.applicationStorageID,
                profileStorageID: source.profileStorageID)
            let folder: PresetIsolationFolder = preset == .firefox ? .firefoxProfile : .extensions
            let target = folder.managedPath(in: paths)
            try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o770])
            let analysis = await LaunchConfigurationCompiler(processEnvironment: [:]).analyze(source)
            XCTAssertEqual(analysis.isolation.presetFolders[folder], .managed(target.url))
            XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: target.url).posixPermissions, 0o770)
        }
    }

    func testCustomPresetDoesNotAddNewIsolationOptions() async throws {
        let prepared = try await LaunchConfigurationCompiler(processEnvironment: [:]).prepare(source(.custom))
        XCTAssertTrue(prepared.arguments.isEmpty)
    }
}

private struct PresetDeniedWriteAccess: PathWriteAccessChecking {
    let denied: URL
    func isWritable(at url: URL) -> Bool { url.standardizedFileURL.path != denied.standardizedFileURL.path }
}
