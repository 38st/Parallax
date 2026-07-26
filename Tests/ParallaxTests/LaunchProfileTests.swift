import XCTest
@testable import Parallax

final class LaunchProfileTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var createdUserDefaultsSuites: [(UserDefaults, String)] = []

    override func setUpWithError() throws {
        createdUserDefaultsSuites = []
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    func testNewProfilesDefaultToExplicitOwnershipAndSafeEnvironment() {
        let profile = LaunchProfile(name: "New")

        XCTAssertEqual(profile.isolationOwnership, .explicit)
        XCTAssertEqual(profile.childEnvironmentPolicy, .safeDefault)
        XCTAssertEqual(profile.launchConfigurationTrust, .local)
    }

    func testProfileEncodingStoresKeychainReferenceButNoResolvedSecret()
        throws
    {
        let reference = EnvironmentSecretReference(
            id: try XCTUnwrap(
                UUID(
                    uuidString:
                        "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
                )
            )
        )
        let profile = LaunchProfile(
            name: "Secret",
            environmentText: "OPENAI_API_KEY=\(reference.token)"
        )

        let encoded = try JSONEncoder().encode(profile)
        let text = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )

        XCTAssertTrue(text.contains(reference.token))
        XCTAssertFalse(text.contains("resolved-secret"))
    }

    override func tearDownWithError() throws {
        for (userDefaults, suiteName) in createdUserDefaultsSuites {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        createdUserDefaultsSuites = []
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testCodexGetsUserDataDirDefaultProfile() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)

        XCTAssertEqual(store.applications.first?.displayName, "Codex")
        XCTAssertEqual(store.applications.first?.profiles.first?.name, "Personal")
        let application = try? XCTUnwrap(store.applications.first)
        let profile = try? XCTUnwrap(application?.profiles.first)
        let expectedDirectory = application.flatMap { application in
            profile.map { store.profileFolderPath(for: application, profile: $0) }
        }
        XCTAssertEqual(
            profile.map(store.resolvedArguments(for:)),
            expectedDirectory.map { ["--user-data-dir=\($0)/UserData"] }
        )
        XCTAssertEqual(
            profile.flatMap { Dictionary(uniqueKeysWithValues: store.resolvedEnvironment(for: $0))["CODEX_HOME"] },
            expectedDirectory.map { "\($0)/CodexHome" }
        )
        XCTAssertEqual(
            profile?.isolationOwnership,
            ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
    }

    func testExpandsTildeAfterEqualsInLaunchArguments() {
        let argument = PathSpecificTildeExpander(
            homeDirectory:
                FileManager.default.homeDirectoryForCurrentUser.path
        ).argumentValue(
            "~/Library/Application Support/Parallax/Profiles/Codex/Personal/UserData",
            forOption: "--user-data-dir"
        )

        XCTAssertTrue(argument.hasPrefix("/"))
        XCTAssertFalse(argument.hasPrefix("~"))
        XCTAssertTrue(argument.hasSuffix("/Library/Application Support/Parallax/Profiles/Codex/Personal/UserData"))
    }

    func testShellParserPreservesEmptyQuotedArguments() {
        XCTAssertEqual(
            ShellWordsParser.parse("--flag \"\" 'two words' plain\\ value"),
            ["--flag", "", "two words", "plain value"]
        )
    }

    func testShellQuotingRoundTripsArgumentsWithSpacesAndQuotes() {
        let arguments = ["--flag=two words", "don't", ""]
        let encoded = arguments.map(ShellWordsParser.quote).joined(separator: " ")

        XCTAssertEqual(ShellWordsParser.parse(encoded), arguments)
    }

    func testShellParserPreservesBackslashesInsideSingleQuotes() {
        XCTAssertEqual(
            ShellWordsParser.parse("'C:\\Users\\Name' \"a\\\"b\""),
            ["C:\\Users\\Name", "a\"b"]
        )
    }

    @MainActor
    func testDuplicateUserDataDirectoryIsNotTreatedAsConfigured() throws {
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )
        let userData = temporaryDirectory.appendingPathComponent("UserData", isDirectory: true)
        let profile = LaunchProfile(
            name: "Personal",
            argumentsText: "--user-data-dir=\" \" --user-data-dir=\"\(userData.path)\""
        )
        let application = ManagedApplication(
            displayName: "Codex",
            appPath: temporaryDirectory
                .appendingPathComponent("Codex.app")
                .path,
            preset: .codex,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )

        XCTAssertFalse(store.hasUserDataDirectoryConfigured(in: profile))
        XCTAssertNil(
            store.userDataPath(
                for: application,
                profile: profile
            )
        )
        XCTAssertFalse(
            store.revealUserData(
                for: application,
                profile: profile
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: userData.path))
    }

    @MainActor
    func testNewCodexProfilesInheritIsolationSettings() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        store.addProfile(named: "Work")

        let application = store.applications.first
        let workProfile = application?.profiles.first { $0.name == "Work" }
        let expectedDirectory = application.flatMap { application in
            workProfile.map { store.profileFolderPath(for: application, profile: $0) }
        }
        XCTAssertEqual(
            workProfile.map(store.resolvedArguments(for:)),
            expectedDirectory.map { ["--user-data-dir=\($0)/UserData"] }
        )
        XCTAssertEqual(
            workProfile.flatMap { Dictionary(uniqueKeysWithValues: store.resolvedEnvironment(for: $0))["CODEX_HOME"] },
            expectedDirectory.map { "\($0)/CodexHome" }
        )
    }

    @MainActor
    func testWarningsIdentifyMissingCodexIsolationSettings() throws {
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )
        let application = ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            profiles: []
        )
        let profile = LaunchProfile(name: "Shared")

        XCTAssertEqual(store.warnings(for: application, profile: profile).count, 2)
    }

    @MainActor
    func testBlankIsolationSettingsAreTreatedAsMissing() async throws {
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )
        let application = ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            profiles: []
        )
        let profile = LaunchProfile(
            name: "Shared",
            argumentsText: "--user-data-dir= ",
            environmentText: "CODEX_HOME= "
        )

        XCTAssertFalse(store.hasCodexHomeConfigured(in: profile))
        XCTAssertFalse(store.hasUserDataDirectoryConfigured(in: profile))
        XCTAssertEqual(store.warnings(for: application, profile: profile).count, 3)

        let healthItems = Dictionary(
            uniqueKeysWithValues:
                await store.refreshHealthItems(
                    for: application,
                    profile: profile
                )
        )
        XCTAssertEqual(healthItems["CODEX_HOME"], false)
        XCTAssertEqual(healthItems["User data flag"], false)
    }

    @MainActor
    func testRenameKeepsStableProfileFolder() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        guard var profile = store.selectedProfile, let application = store.selectedApplication else {
            XCTFail("Expected a selected profile")
            return
        }

        let originalPath = store.profileFolderPath(for: application, profile: profile)
        profile.name = "Renamed"
        store.updateProfile(profile)

        guard let updatedProfile = store.selectedProfile else {
            XCTFail("Expected an updated profile")
            return
        }

        XCTAssertEqual(store.profileFolderPath(for: application, profile: updatedProfile), originalPath)
    }

    @MainActor
    func testProfileFolderDisplayPathMatchesCanonicalNamespaceCasing()
        throws
    {
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )
        let profile = LaunchProfile(name: "Case Sensitive")
        let application = ManagedApplication(
            displayName: "Fixture",
            appPath: "/Applications/Fixture.app",
            preset: .custom,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )

        let displayPath = store.profileFolderDisplayPath(
            for: application,
            profile: profile
        )

        XCTAssertEqual(
            displayPath,
            store.profileFolderPath(
                for: application,
                profile: profile
            )
        )
        XCTAssertTrue(displayPath.contains("/Applications/"))
        XCTAssertTrue(displayPath.contains("/Profiles/"))
        XCTAssertFalse(displayPath.contains("/apps/"))
        XCTAssertFalse(displayPath.contains("/profiles/"))
    }

    @MainActor
    func testDuplicatingProfileRewritesIsolationPaths() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        store.duplicateSelectedProfile()

        let profiles = store.applications.first?.profiles ?? []
        XCTAssertEqual(profiles.count, 2)
        XCTAssertNotEqual(profiles[0].storageID, profiles[1].storageID)
        XCTAssertNotEqual(profiles[0].environment["CODEX_HOME"], profiles[1].environment["CODEX_HOME"])
        XCTAssertNotEqual(profiles[0].arguments.first, profiles[1].arguments.first)
    }

    @MainActor
    func testDuplicatingProfileCreatesUniqueVisibleNames() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        store.duplicateSelectedProfile()
        store.selectedProfileID = store.applications.first?.profiles.first?.id
        store.duplicateSelectedProfile()

        let names = store.applications.first?.profiles.map(\.name)
        XCTAssertEqual(names, ["Personal", "Personal Copy", "Personal Copy 2"])
    }

    @MainActor
    func testRewritingRecommendedSettingsPreservesQuotedArguments() throws {
        let profile = LaunchProfile(
            name: "Personal",
            argumentsText: "--flag=\"two words\" --user-data-dir=/tmp/old",
            environmentText: "CODEX_HOME = /tmp/old"
        )
        let application = ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        store.applyRecommendedSettings(to: profile)

        let updatedProfile = store.applications.first?.profiles.first
        XCTAssertEqual(updatedProfile?.arguments.first, "--flag=two words")
        XCTAssertEqual(updatedProfile?.arguments.count, 2)
        XCTAssertEqual(
            updatedProfile?.environmentText
                .split(whereSeparator: \.isNewline)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("CODEX_HOME") }
                .count,
            1
        )
        XCTAssertEqual(
            updatedProfile?.environment["CODEX_HOME"],
            " /tmp/old",
            "An explicit external isolation value, including meaningful whitespace after '=', must not be silently rewritten"
        )
    }

    @MainActor
    func testRecommendedSettingsReplaceBlankIsolationValues() throws {
        let profile = LaunchProfile(
            name: "Personal",
            argumentsText: "--flag --user-data-dir=",
            environmentText: "CODEX_HOME = "
        )
        let application = ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        store.applyRecommendedSettings(to: profile)

        let updatedProfile = store.applications.first?.profiles.first
        let expectedDirectory = updatedProfile.map {
            store.profileFolderPath(for: application, profile: $0)
        }
        XCTAssertEqual(updatedProfile?.arguments.first, "--flag")
        XCTAssertEqual(
            updatedProfile.map(store.resolvedArguments(for:))?.last,
            expectedDirectory.map { "--user-data-dir=\($0)/UserData" }
        )
        XCTAssertEqual(
            updatedProfile.flatMap {
                Dictionary(uniqueKeysWithValues: store.resolvedEnvironment(for: $0))["CODEX_HOME"]
            },
            expectedDirectory.map { "\($0)/CodexHome" }
        )
    }

    @MainActor
    func testDirectIsolationEditsBecomeExplicit() throws {
        let profile = LaunchProfile(
            name: "Personal",
            argumentsText: "--user-data-dir=/managed/user-data",
            environmentText: "CODEX_HOME=/managed/codex-home",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
        let application = ManagedApplication(
            displayName: "Codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            launcher: DeferredLauncher(),
            settings: try makeIsolatedSettings()
        )
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id
        var edited = profile
        edited.argumentsText = "--user-data-dir=/external/user-data"
        edited.environmentText = "CODEX_HOME=/external/codex-home"

        store.updateProfile(edited)

        XCTAssertEqual(
            store.selectedProfile?.isolationOwnership,
            .explicit
        )
    }

    @MainActor
    func testUnrelatedLaunchEditsPreserveGeneratedIsolationOwnership()
        throws
    {
        let codexURL = temporaryDirectory.appendingPathComponent(
            "Codex.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexURL,
            withIntermediateDirectories: true
        )
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            launcher: DeferredLauncher(),
            settings: try makeIsolatedSettings()
        )
        store.addApplication(at: codexURL)
        var profile = try XCTUnwrap(store.selectedProfile)
        XCTAssertEqual(
            profile.isolationOwnership,
            ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )

        profile.argumentsText += " --enable-feature"
        profile.environmentText += "\nLABEL=literal"
        store.updateProfile(profile)

        XCTAssertEqual(
            store.selectedProfile?.isolationOwnership,
            ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
    }

    func testDecodesLegacyApplicationWithoutPresetFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Codex",
          "bundleIdentifier": "com.openai.codex",
          "appPath": "/Applications/Codex.app",
          "profiles": []
        }
        """

        let application = try JSONDecoder().decode(
            LegacyManagedApplication.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(application.preset, .automatic)
        XCTAssertNil(application.baseStoragePath)
    }

    func testPersistenceWritesVersionedLibraryDocumentAndReadsLegacyArray() throws {
        let persistence = LibraryPersistence(applicationSupportURL: temporaryDirectory)
        let application = ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            profiles: [LaunchProfile(name: "Personal")]
        )

        try persistence.save([application])

        let libraryURL = temporaryDirectory
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json")
        let data = try Data(contentsOf: libraryURL)
        let document = try JSONDecoder().decode(LibraryDocument.self, from: data)
        XCTAssertEqual(document.version, LibraryDocument.currentVersion)
        XCTAssertEqual(document.applications.count, 1)

        let legacyData = try JSONEncoder().encode([application])
        let result = try LibraryPersistence.decodeLibrary(from: legacyData)
        guard case let .migrationRequired(legacy) = result else {
            XCTFail("Raw arrays must remain legacy migration input")
            return
        }
        XCTAssertEqual(legacy.applications.count, 1)
    }

    @MainActor
    func testRemovingProfileCanArchiveData() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        guard let application = store.selectedApplication, let profile = store.selectedProfile else {
            XCTFail("Expected selected app and profile")
            return
        }

        let profilePath = store.profileFolderPath(for: application, profile: profile)
        try FileManager.default.createDirectory(atPath: profilePath, withIntermediateDirectories: true)
        try "sentinel".write(
            toFile: (profilePath as NSString).appendingPathComponent("sentinel.txt"),
            atomically: true,
            encoding: .utf8
        )

        store.remove(profile: profile, dataRemoval: .archive)

        XCTAssertTrue(store.applications.first?.profiles.isEmpty == true)
        let archivesPath = try store.managedPaths(
            for: application,
            profile: profile
        ).archiveRoot.url
        let archivedItems = try FileManager.default.contentsOfDirectory(atPath: archivesPath.path)
        let archivedSentinelExists = archivedItems.contains { item in
            let sentinelPath = ((archivesPath.path as NSString).appendingPathComponent(item) as NSString)
                .appendingPathComponent("sentinel.txt")
            return FileManager.default.fileExists(atPath: sentinelPath)
        }
        XCTAssertTrue(archivedSentinelExists)
    }

    @MainActor
    func testRepeatedClearCreatesDistinctArchives() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        guard let application = store.selectedApplication, let profile = store.selectedProfile else {
            XCTFail("Expected selected app and profile")
            return
        }

        let profilePath = store.profileFolderPath(for: application, profile: profile)
        try FileManager.default.createDirectory(atPath: profilePath, withIntermediateDirectories: true)
        try "one".write(
            toFile: (profilePath as NSString).appendingPathComponent("one.txt"),
            atomically: true,
            encoding: .utf8
        )
        store.clearProfileData(for: application, profile: profile)

        try FileManager.default.createDirectory(
            atPath: profilePath,
            withIntermediateDirectories: true
        )
        try "two".write(
            toFile: (profilePath as NSString).appendingPathComponent("two.txt"),
            atomically: true,
            encoding: .utf8
        )
        store.clearProfileData(for: application, profile: profile)

        let archivesPath = try store.managedPaths(
            for: application,
            profile: profile
        ).archiveRoot.url
        let archivedItems = try FileManager.default.contentsOfDirectory(atPath: archivesPath.path)
        XCTAssertGreaterThanOrEqual(archivedItems.count, 2)
    }

    @MainActor
    func testLaunchCompletionAfterProfileRemovalDoesNotCrashOrRewriteWrongProfile() async throws {
        let launcher = DeferredLauncher()
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: launcher,
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        guard let profile = store.selectedProfile else {
            XCTFail("Expected selected profile")
            return
        }

        store.launch(profile)
        store.remove(profile: profile, dataRemoval: .keep)
        launcher.complete(.success(()))
        for _ in 0..<10 where store.launchStatusMessage?.contains("Launched Personal") != true {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(store.applications.first?.profiles.isEmpty == true)
        XCTAssertTrue(store.launchStatusMessage?.contains("Launched Personal") == true)
    }

    func testUnsupportedLibraryVersionIsRejected() {
        let unsupportedVersion = LibraryDocument.currentVersion + 1
        let json = """
        {
          "version": \(unsupportedVersion),
          "applications": []
        }
        """

        XCTAssertThrowsError(try LibraryPersistence.decodeApplications(from: Data(json.utf8))) { error in
            guard case .unsupportedVersion(let found, let supported) = error as? LibraryPersistenceError else {
                XCTFail("Expected LibraryPersistenceError.unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(found, unsupportedVersion)
            XCTAssertEqual(supported, LibraryDocument.currentVersion)
        }
    }

    func testCurrentVersionLibraryDecodesSuccessfully() throws {
        let json = """
        {
          "version": \(LibraryDocument.currentVersion),
          "applications": []
        }
        """

        let applications = try LibraryPersistence.decodeApplications(from: Data(json.utf8))
        XCTAssertTrue(applications.isEmpty)
    }

    func testAppPresetDetectionUsesWordBoundaries() {
        XCTAssertEqual(AppPreset.detected(displayName: "Wedge", bundleIdentifier: nil), .custom)
        XCTAssertEqual(AppPreset.detected(displayName: "Hedge", bundleIdentifier: nil), .custom)
        XCTAssertEqual(AppPreset.detected(displayName: "Knowledge", bundleIdentifier: nil), .custom)
        XCTAssertEqual(AppPreset.detected(displayName: "Edge", bundleIdentifier: nil), .edge)
        XCTAssertEqual(AppPreset.detected(displayName: "Microsoft Edge", bundleIdentifier: nil), .edge)
        XCTAssertEqual(AppPreset.detected(displayName: "Chrome", bundleIdentifier: nil), .chrome)
        XCTAssertEqual(AppPreset.detected(displayName: "Google Chrome", bundleIdentifier: nil), .chrome)
        XCTAssertEqual(AppPreset.detected(displayName: "Chromium", bundleIdentifier: nil), .chromium)
        XCTAssertEqual(AppPreset.detected(displayName: "Brave Browser", bundleIdentifier: nil), .brave)
        XCTAssertEqual(AppPreset.detected(displayName: "Codex", bundleIdentifier: nil), .codex)
        XCTAssertEqual(AppPreset.detected(displayName: "Electron", bundleIdentifier: nil), .electron)
        XCTAssertEqual(AppPreset.detected(displayName: "My Electron App", bundleIdentifier: "com.electron.myapp"), .electron)
        XCTAssertEqual(AppPreset.detected(displayName: "Random", bundleIdentifier: "com.microsoft.something"), .edge)
    }

    @MainActor
    func testAddApplicationRejectsNonAppBundles() throws {
        let txtURL = temporaryDirectory.appendingPathComponent("notes.txt", isDirectory: false)
        try "hello".write(to: txtURL, atomically: true, encoding: .utf8)

        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: DeferredLauncher(),
            settings: try makeIsolatedSettings()
        )

        let initialCount = store.applications.count
        store.addApplication(at: txtURL)

        XCTAssertEqual(store.applications.count, initialCount)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testAddingSameApplicationSelectsExistingEntry() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: DeferredLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        let applicationID = store.selectedApplicationID
        let profileID = store.selectedProfileID

        store.addApplication(at: codexURL)

        XCTAssertEqual(store.applications.count, 1)
        XCTAssertEqual(store.selectedApplicationID, applicationID)
        XCTAssertEqual(store.selectedProfileID, profileID)
        XCTAssertEqual(store.launchStatusMessage, "Codex is already in the library.")
    }

    @MainActor
    func testRepeatedTemplateProfileNamesStayDistinct() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: DeferredLauncher(),
            settings: try makeIsolatedSettings()
        )

        store.addApplication(at: codexURL)
        store.addProfile(named: "Work")
        store.addProfile(named: "Work")

        let profiles = try XCTUnwrap(store.applications.first?.profiles)
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Work", "Work 2"])
        XCTAssertEqual(Set(profiles.map(\.storageID)).count, 3)
    }

    @MainActor
    func testAppSettingsPersistsAcrossInstances() throws {
        let (userDefaults, suiteName) = try makeTestUserDefaults()
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(userDefaults: userDefaults)
        first.profileTemplates = [
            ProfileTemplate(name: "Alpha"),
            ProfileTemplate(name: "Beta")
        ]
        first.defaultBaseStoragePath = "/tmp/ParallaxData"
        first.confirmBeforeLaunch = true
        first.appearance = .dark

        let second = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(second.profileTemplateNames, ["Alpha", "Beta"])
        XCTAssertEqual(second.defaultBaseStoragePath, "/tmp/ParallaxData")
        XCTAssertTrue(second.confirmBeforeLaunch)
        XCTAssertEqual(second.appearance, .dark)
    }

    @MainActor
    func testAppSettingsFallsBackToDefaultsWhenEmpty() throws {
        let (userDefaults, suiteName) = try makeTestUserDefaults()
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(settings.profileTemplateNames, AppSettings.defaultProfileTemplateNames)
        XCTAssertEqual(settings.defaultBaseStoragePath, "")
        XCTAssertFalse(settings.confirmBeforeLaunch)
        XCTAssertEqual(settings.appearance, .system)
    }

    @MainActor
    func testLaunchConfirmationFlowDefersLaunchUntilConfirmed() async throws {
        let launcher = DeferredLauncher()
        let (userDefaults, suiteName) = try makeTestUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults)
        settings.confirmBeforeLaunch = true
        settings.defaultBaseStoragePath = temporaryDirectory.path

        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: launcher,
            settings: settings
        )

        store.addApplication(at: codexURL)
        guard let profile = store.selectedProfile else {
            XCTFail("Expected selected profile")
            return
        }

        store.launch(profile)
        XCTAssertEqual(launcher.launchCount, 0, "Launcher must not be invoked before confirmation")
        XCTAssertTrue(store.isShowingLaunchConfirmation)
        XCTAssertEqual(store.pendingLaunchProfileName, profile.name)

        store.confirmLaunch()
        XCTAssertEqual(launcher.launchCount, 1, "Launcher must be invoked after confirmation")
        XCTAssertFalse(store.isShowingLaunchConfirmation)

        launcher.complete(.success(()))
        for _ in 0..<10 where store.launchStatusMessage?.contains("Launched \(profile.name)") != true {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.launchStatusMessage?.contains("Launched \(profile.name)") == true)
    }

    @MainActor
    func testCancelLaunchDoesNotLaunch() throws {
        let launcher = DeferredLauncher()
        let (userDefaults, suiteName) = try makeTestUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults)
        settings.confirmBeforeLaunch = true
        settings.defaultBaseStoragePath = temporaryDirectory.path

        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: launcher,
            settings: settings
        )

        store.addApplication(at: codexURL)
        guard let profile = store.selectedProfile else {
            XCTFail("Expected selected profile")
            return
        }

        store.launch(profile)
        store.cancelLaunch()

        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertFalse(store.isShowingLaunchConfirmation)
        XCTAssertNil(store.pendingLaunchProfileName)
    }

    @MainActor
    func testLaunchConfirmationUsesOriginalApplicationAfterSelectionChanges() throws {
        let launcher = DeferredLauncher()
        let (userDefaults, suiteName) = try makeTestUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults)
        settings.confirmBeforeLaunch = true
        settings.defaultBaseStoragePath = temporaryDirectory.path

        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        let chromeURL = temporaryDirectory.appendingPathComponent("Google Chrome.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: chromeURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: launcher,
            settings: settings
        )

        store.addApplication(at: codexURL)
        guard let codexApplication = store.selectedApplication,
              let codexProfile = store.selectedProfile
        else {
            XCTFail("Expected Codex app and profile")
            return
        }

        store.addApplication(at: chromeURL)
        guard let chromeApplication = store.selectedApplication,
              let chromeProfile = store.selectedProfile
        else {
            XCTFail("Expected Chrome app and profile")
            return
        }

        store.selectedApplicationID = codexApplication.id
        store.selectedProfileID = codexProfile.id
        store.launch(codexProfile)
        XCTAssertTrue(store.isShowingLaunchConfirmation)

        store.selectedApplicationID = chromeApplication.id
        store.selectedProfileID = chromeProfile.id
        store.confirmLaunch()

        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(launcher.launchedApplicationIDs, [codexApplication.id])
        XCTAssertEqual(launcher.launchedProfileIDs, [codexProfile.id])
        XCTAssertEqual(store.selectedApplicationID, codexApplication.id)
        XCTAssertEqual(store.selectedProfileID, codexProfile.id)
    }

    @MainActor
    func testHealthPathsUseConfiguredCodexHomeAndUserDataDir()
        async throws
    {
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: DeferredLauncher(),
            settings: try makeIsolatedSettings()
        )
        let customCodexHome = temporaryDirectory.appendingPathComponent("External Codex Home", isDirectory: true)
        let customUserData = temporaryDirectory.appendingPathComponent("External User Data", isDirectory: true)
        try FileManager.default.createDirectory(at: customCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customUserData, withIntermediateDirectories: true)

        let profile = LaunchProfile(
            name: "Custom",
            argumentsText: "--user-data-dir=\"\(customUserData.path)\"",
            environmentText: "CODEX_HOME=\(customCodexHome.path)"
        )
        let application = ManagedApplication(
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            profiles: [profile]
        )

        XCTAssertEqual(store.codexHomePath(for: application, profile: profile), customCodexHome.path)
        XCTAssertEqual(store.userDataPath(for: application, profile: profile), customUserData.path)

        let healthItems = Dictionary(
            uniqueKeysWithValues:
                await store.refreshHealthItems(
                    for: application,
                    profile: profile
                )
        )
        XCTAssertEqual(healthItems["CODEX_HOME"], true)
        XCTAssertEqual(healthItems["Codex home folder"], true)
        XCTAssertEqual(healthItems["User data flag"], true)
        XCTAssertEqual(healthItems["User data folder"], true)
    }

    @MainActor
    func testLegacyTemplateNamesArePersistedWhenMigrated() throws {
        let (userDefaults, suiteName) = try makeTestUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(["Client", "Lab"], forKey: "settings.profileTemplateNames")

        let first = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(first.profileTemplateNames, ["Client", "Lab"])
        XCTAssertNil(userDefaults.object(forKey: "settings.profileTemplateNames"))

        let second = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(second.profileTemplateNames, ["Client", "Lab"])
    }

    @MainActor
    private func makeIsolatedSettings(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AppSettings {
        let (userDefaults, _) = try makeTestUserDefaults(file: file, line: line)
        let settings = AppSettings(userDefaults: userDefaults)
        settings.defaultBaseStoragePath = temporaryDirectory.path
        return settings
    }

    private func makeTestUserDefaults(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (userDefaults: UserDefaults, suiteName: String) {
        let suiteName = "parallax.tests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        userDefaults.removePersistentDomain(forName: suiteName)
        createdUserDefaultsSuites.append((userDefaults, suiteName))
        return (userDefaults, suiteName)
    }
}

private final class DeferredLauncher: ApplicationLaunching {
    private let lock = NSLock()
    private var storedCompletion: (@Sendable (Result<Void, Error>) -> Void)?
    private(set) var launchCount: Int = 0
    private(set) var launchedApplicationIDs: [ManagedApplication.ID] = []
    private(set) var launchedProfileIDs: [LaunchProfile.ID] = []

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.lock()
        storedCompletion = completion
        launchCount += 1
        launchedApplicationIDs.append(application.id)
        launchedProfileIDs.append(profile.id)
        lock.unlock()
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let completion = storedCompletion
        storedCompletion = nil
        lock.unlock()
        completion?(result)
    }
}
