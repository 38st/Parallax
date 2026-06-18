import XCTest
@testable import Parallax

final class LaunchProfileTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    @MainActor
    func testCodexGetsUserDataDirDefaultProfile() {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher()
        )

        store.addApplication(at: codexURL)

        XCTAssertEqual(store.applications.first?.displayName, "Codex")
        XCTAssertEqual(store.applications.first?.profiles.first?.name, "Personal")
        XCTAssertEqual(
            store.applications.first?.profiles.first?.arguments,
            ["--user-data-dir=\(LibraryStore.defaultProfilesRootPath)/Codex/Personal/UserData"]
        )
        XCTAssertEqual(
            store.applications.first?.profiles.first?.environment["CODEX_HOME"],
            "\(LibraryStore.defaultProfilesRootPath)/Codex/Personal/CodexHome"
        )
    }

    func testExpandsTildeAfterEqualsInLaunchArguments() {
        let argument = WorkspaceApplicationLauncher.expandingTildeInArgument(
            "--user-data-dir=~/Library/Application Support/Parallax/Profiles/Codex/Personal/UserData"
        )

        XCTAssertTrue(argument.hasPrefix("--user-data-dir=/"))
        XCTAssertFalse(argument.contains("=~"))
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

    func testCreatesCodexHomeBeforeLaunching() throws {
        let codexHome = temporaryDirectory.appendingPathComponent("CodexHome", isDirectory: true)

        try WorkspaceApplicationLauncher.createKnownHomeDirectories(in: [
            "CODEX_HOME": codexHome.path
        ])

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testNewCodexProfilesInheritIsolationSettings() {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher()
        )

        store.addApplication(at: codexURL)
        store.addProfile(named: "Work")

        let workProfile = store.applications.first?.profiles.first { $0.name == "Work" }
        XCTAssertEqual(
            workProfile?.arguments,
            ["--user-data-dir=\(LibraryStore.defaultProfilesRootPath)/Codex/Work/UserData"]
        )
        XCTAssertEqual(
            workProfile?.environment["CODEX_HOME"],
            "\(LibraryStore.defaultProfilesRootPath)/Codex/Work/CodexHome"
        )
    }

    @MainActor
    func testWarningsIdentifyMissingCodexIsolationSettings() {
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher()
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
    func testRenameKeepsStableProfileFolder() {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher()
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
    func testDuplicatingProfileRewritesIsolationPaths() {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher()
        )

        store.addApplication(at: codexURL)
        store.duplicateSelectedProfile()

        let profiles = store.applications.first?.profiles ?? []
        XCTAssertEqual(profiles.count, 2)
        XCTAssertNotEqual(profiles[0].storageName, profiles[1].storageName)
        XCTAssertNotEqual(profiles[0].environment["CODEX_HOME"], profiles[1].environment["CODEX_HOME"])
        XCTAssertNotEqual(profiles[0].arguments.first, profiles[1].arguments.first)
    }

    @MainActor
    func testRewritingRecommendedSettingsPreservesQuotedArguments() {
        let profile = LaunchProfile(
            name: "Personal",
            argumentsText: "--flag=\"two words\" --user-data-dir=/tmp/old",
            environmentText: "CODEX_HOME = /tmp/old",
            storageName: "Personal"
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
            launcher: WorkspaceApplicationLauncher()
        )
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        store.updateApplication(application)

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
        XCTAssertTrue(updatedProfile?.environment["CODEX_HOME"]?.hasSuffix("/CodexHome") == true)
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

        let application = try JSONDecoder().decode(ManagedApplication.self, from: Data(json.utf8))

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
        let legacyApplications = try LibraryPersistence.decodeApplications(from: legacyData)
        XCTAssertEqual(legacyApplications.count, 1)
    }

    @MainActor
    func testRemovingProfileCanArchiveData() throws {
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: WorkspaceApplicationLauncher()
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
        let archivesPath = ((profilePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("Archives")
        let archivedItems = try FileManager.default.contentsOfDirectory(atPath: archivesPath)
        let archivedSentinelExists = archivedItems.contains { item in
            let sentinelPath = ((archivesPath as NSString).appendingPathComponent(item) as NSString)
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
            launcher: WorkspaceApplicationLauncher()
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

        try "two".write(
            toFile: (profilePath as NSString).appendingPathComponent("two.txt"),
            atomically: true,
            encoding: .utf8
        )
        store.clearProfileData(for: application, profile: profile)

        let archivesPath = ((profilePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("Archives")
        let archivedItems = try FileManager.default.contentsOfDirectory(atPath: archivesPath)
        XCTAssertGreaterThanOrEqual(archivedItems.count, 2)
    }

    @MainActor
    func testLaunchCompletionAfterProfileRemovalDoesNotCrashOrRewriteWrongProfile() async {
        let launcher = DeferredLauncher()
        let codexURL = temporaryDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: launcher
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
            launcher: DeferredLauncher()
        )

        let initialCount = store.applications.count
        store.addApplication(at: txtURL)

        XCTAssertEqual(store.applications.count, initialCount)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testAppSettingsPersistsAcrossInstances() {
        let suiteName = "parallax.tests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
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
    func testAppSettingsFallsBackToDefaultsWhenEmpty() {
        let suiteName = "parallax.tests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: userDefaults)
        XCTAssertEqual(settings.profileTemplateNames, AppSettings.defaultProfileTemplateNames)
        XCTAssertEqual(settings.defaultBaseStoragePath, "")
        XCTAssertFalse(settings.confirmBeforeLaunch)
        XCTAssertEqual(settings.appearance, .system)
    }

    @MainActor
    func testLaunchConfirmationFlowDefersLaunchUntilConfirmed() async {
        let launcher = DeferredLauncher()
        let settings = AppSettings(userDefaults: UserDefaults(suiteName: "parallax.tests.\(UUID().uuidString)")!)
        settings.confirmBeforeLaunch = true

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
    func testCancelLaunchDoesNotLaunch() {
        let launcher = DeferredLauncher()
        let settings = AppSettings(userDefaults: UserDefaults(suiteName: "parallax.tests.\(UUID().uuidString)")!)
        settings.confirmBeforeLaunch = true

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
}

private final class DeferredLauncher: ApplicationLaunching {
    private let lock = NSLock()
    private var storedCompletion: (@Sendable (Result<Void, Error>) -> Void)?
    private(set) var launchCount: Int = 0

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.lock()
        storedCompletion = completion
        launchCount += 1
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
