import XCTest
@testable import Parallax

@MainActor
final class CodexSharedWorkspaceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let repository: LibraryRepository
        let store: LibraryStore
        var app: ManagedApplication
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexWorkspace-\(UUID())")
        let home = root.appendingPathComponent("Main History")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let app = ManagedApplication(displayName: "Synthetic Codex", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .codex, baseStoragePath: root.path,
            profiles: [LaunchProfile(name: "First"), LaunchProfile(name: "Second")])
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        return Fixture(root: root, home: home, repository: repository,
            store: LibraryStore(repository: repository, settings: AppSettings()), app: app)
    }

    private func enable(_ f: Fixture) throws {
        try f.store.setCodexSharedWorkspace(true, application: f.app, expected: nil, home: f.home)
    }

    private func source(_ f: Fixture, profile: LaunchProfile? = nil, request: UUID = UUID()) -> LaunchConfigurationSource {
        f.store.launchConfigurationSource(application: f.app, profile: profile ?? f.app.profiles[0], requestID: request)
    }

    func testMainDestinationRequiresExplicitChoiceAndPersistsItWithoutChangingStorage() throws {
        let f = try fixture()
        try enable(f)
        let initial = try XCTUnwrap(f.store.codexSharedWorkspace(f.app))
        XCTAssertNil(initial.launchProfileStorageID)
        let selected = f.app.profiles[1]
        try f.store.setCodexMainLaunchProfile(selected.storageID, application: f.app, expected: initial)
        let updated = try XCTUnwrap(f.store.codexSharedWorkspace(f.app))
        XCTAssertEqual(updated.path, initial.path)
        XCTAssertEqual(updated.inode, initial.inode)
        XCTAssertEqual(updated.launchProfileStorageID, selected.storageID)
        XCTAssertNoThrow(try updated.validate())
        let restarted = LibraryStore(repository: f.repository, settings: AppSettings())
        XCTAssertEqual(try restarted.codexSharedWorkspace(f.app), updated)
        XCTAssertEqual(restarted.applications, f.store.applications)
        XCTAssertThrowsError(try f.store.setCodexMainLaunchProfile(UUID(), application: f.app, expected: updated))
        XCTAssertThrowsError(try f.store.setCodexMainLaunchProfile(f.app.profiles[0].storageID, application: f.app, expected: initial))
        XCTAssertEqual(try f.store.codexSharedWorkspace(f.app), updated)
    }

    func testPreferenceSurvivesRestartAndNeverRewritesHistoryOrSavedProfiles() throws {
        let f = try fixture()
        let marker = f.home.appendingPathComponent("history-and-projects.fixture")
        let bytes = Data("synthetic untouched provider data".utf8)
        try bytes.write(to: marker)
        let original = f.store.applications
        try enable(f)
        let restarted = LibraryStore(repository: f.repository, settings: AppSettings())
        XCTAssertEqual(try restarted.codexSharedWorkspace(f.app)?.path, f.home.path)
        XCTAssertEqual(f.store.applications, original)
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.home.path), [marker.lastPathComponent])
    }

    func testCurrentAndFutureAccountsUseSameHomeAndOffRestoresTheirSettings() throws {
        var f = try fixture()
        let before = source(f)
        try enable(f)
        let future = LaunchProfile(name: "Future")
        f.app.profiles.append(future)
        XCTAssertTrue(f.store.commit([f.app], selectedApplicationID: nil, selectedProfileID: nil))
        for profile in f.app.profiles {
            let routed = source(f, profile: profile)
            XCTAssertEqual(LaunchEnvironmentParser.parse(routed.environmentText).effectiveValues["CODEX_HOME"], f.home.path)
            XCTAssertEqual(routed.codexSharedWorkspace?.path, f.home.path)
        }
        let current = try f.store.codexSharedWorkspace(f.app)
        try f.store.setCodexSharedWorkspace(false, application: f.app, expected: current)
        let after = source(f)
        XCTAssertNil(after.codexSharedWorkspace)
        XCTAssertEqual(after.environmentText, before.environmentText)
        XCTAssertEqual(after.argumentsText, before.argumentsText)
        XCTAssertNil(f.store.selectedProfileID)
    }

    func testProjectionRemovesSplitStorageAndKeepsUnrelatedArgumentsAndEnvironment() throws {
        let f = try fixture()
        var input = source(f)
        input.argumentsText = "--user-data-dir '/synthetic/separate ui' --example='kept value'"
        input.environmentText = "CODEX_HOME=/synthetic/separate\nCODEX_SQLITE_HOME=/synthetic/db\nCODEX_ELECTRON_USER_DATA_PATH=/synthetic/ui\nEXAMPLE=kept"
        let output = try CodexSharedWorkspace.bind(f.home).project(input)
        XCTAssertEqual(LaunchArgumentParser.parse(output.argumentsText).words, ["--example=kept value"])
        let env = LaunchEnvironmentParser.parse(output.environmentText)
        XCTAssertEqual(env.effectiveValues["EXAMPLE"], "kept")
        XCTAssertEqual(env.effectiveValues["CODEX_HOME"], f.home.path)
        XCTAssertEqual(env.effectiveOperations["CODEX_SQLITE_HOME"], .unset)
        XCTAssertEqual(env.effectiveOperations["CODEX_ELECTRON_USER_DATA_PATH"], .unset)
        XCTAssertEqual(output.isolationOwnership.codexHome, .explicit)
        XCTAssertEqual(output.isolationOwnership.userData, .explicit)
    }

    func testMissingReplacedOrSymlinkedHomeBlocksLaunchWithoutFallback() async throws {
        let f = try fixture()
        try enable(f)
        let saved = f.home.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: f.home, to: saved)
        XCTAssertTrue(source(f).codexSharedWorkspaceInvalid)
        try FileManager.default.createSymbolicLink(at: f.home, withDestinationURL: saved)
        XCTAssertTrue(source(f).codexSharedWorkspaceInvalid)
        try FileManager.default.removeItem(at: f.home)
        try FileManager.default.createDirectory(at: f.home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let blocked = source(f)
        XCTAssertTrue(blocked.codexSharedWorkspaceInvalid)
        let analysis = await LaunchConfigurationCompiler().analyze(blocked)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .sharedCodexWorkspaceUnavailable && !$0.isOverridable })
        // Turning off remains possible even if the original volume is absent.
        try f.store.setCodexSharedWorkspace(false, application: f.app, expected: f.store.codexSharedWorkspace(f.app))
        XCTAssertFalse(source(f).codexSharedWorkspaceInvalid)
    }

    func testChangedPreferenceInvalidatesAnApprovedLaunchInBothDirections() async throws {
        let f = try fixture()
        let separate = source(f)
        try enable(f)
        do { try await f.store.prepareSharedHistoryForLaunch(separate); XCTFail("Stale separate-home approval") }
        catch { XCTAssertEqual(error as? SharedHistoryError, .changed) }
        let shared = source(f)
        try await f.store.prepareSharedHistoryForLaunch(shared)
        try f.store.setCodexSharedWorkspace(false, application: f.app, expected: f.store.codexSharedWorkspace(f.app))
        do { try await f.store.prepareSharedHistoryForLaunch(shared); XCTFail("Stale main-home approval") }
        catch { XCTAssertEqual(error as? SharedHistoryError, .changed) }
    }

    func testCompilerPreparesOneNativeWorkspaceWithoutManagedDirectoryWrites() async throws {
        let f = try fixture()
        try enable(f)
        let prepared = try await LaunchConfigurationCompiler(processEnvironment: ["CODEX_SQLITE_HOME": "/synthetic/wrong"])
            .prepare(source(f))
        XCTAssertEqual(prepared.environment["CODEX_HOME"], f.home.path)
        XCTAssertNil(prepared.environment["CODEX_SQLITE_HOME"])
        XCTAssertFalse(prepared.isolation.managesCodexHome)
        XCTAssertFalse(prepared.isolation.managesUserData)
        XCTAssertTrue(prepared.usesSharedCodexWorkspace)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.home.path).isEmpty)
    }

    func testRootChangeDuringPreparationIsRejected() async throws {
        let f = try fixture()
        try enable(f)
        let home = f.home
        let compiler = LaunchConfigurationCompiler(preparationHook: {
            try FileManager.default.moveItem(at: home, to: home.appendingPathExtension("saved"))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        })
        do { _ = try await compiler.prepare(source(f)); XCTFail("Retargeted workspace") }
        catch { XCTAssertTrue(error is CodexSharedWorkspaceError) }
    }

    func testRevealUsesMainHistoryInsteadOfTheSavedSeparateHome() throws {
        let f = try fixture()
        try enable(f)
        var revealed: URL?
        XCTAssertTrue(f.store.revealCodexHome(for: f.app, profile: f.app.profiles[0],
            revealManaged: { _ in XCTFail("Main home is provider-owned"); return false },
            revealExternal: { revealed = $0.canonicalURL; return true }))
        let target = try CodexSharedWorkspace.bind(XCTUnwrap(revealed))
        let expected = try CodexSharedWorkspace.bind(f.home)
        XCTAssertEqual(target.device, expected.device)
        XCTAssertEqual(target.inode, expected.inode)
        try FileManager.default.moveItem(at: f.home, to: f.home.appendingPathExtension("saved"))
        XCTAssertFalse(f.store.revealCodexHome(for: f.app, profile: f.app.profiles[0],
            revealManaged: { _ in XCTFail("Must not fall back"); return false },
            revealExternal: { _ in XCTFail("Root is missing"); return false }))
    }

    func testTerminalUsesMainHistoryAndClearsInheritedDatabaseOverride() throws {
        let f = try fixture()
        try enable(f)
        let command = try SpaceTerminalService(activityRegistry: ProfileActivityRegistry())
            .prepare(source(f), preset: .codex, loginShell: "/bin/sh", temporaryDirectory: f.root)
        defer { command.cleanup() }
        let script = try String(contentsOf: command.url, encoding: .utf8)
        XCTAssertTrue(script.contains("export CODEX_HOME='\(f.home.path)'"))
        XCTAssertTrue(script.contains("unset CODEX_SQLITE_HOME CODEX_ELECTRON_USER_DATA_PATH"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.home.path).isEmpty)
    }

    func testSchemaMigrationRetainsPreviousReceiptAndRejectsForgedLegacyPolicy() throws {
        let f = try fixture()
        let receipts = try XCTUnwrap(f.store.sharedHistoryStore)
        try receipts.setIncludesAllAccounts(true, applicationID: UUID(), expected: false)
        let directory = try XCTUnwrap(f.store.libraryPrimaryURL).deletingLastPathComponent()
        let path = directory.appendingPathComponent("shared-history.json")
        let before = try Data(contentsOf: path)
        try enable(f)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("shared-history-v3-\(LibraryPersistence.sha256(before)).json")), before)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 4)
        json["schemaVersion"] = 3
        let forged = try JSONSerialization.data(withJSONObject: json)
        try forged.write(to: path)
        XCTAssertThrowsError(try receipts.codexWorkspace(applicationID: f.app.storageID))
        XCTAssertThrowsError(try receipts.setCodexWorkspace(nil, applicationID: f.app.storageID, expected: nil))
        XCTAssertEqual(try Data(contentsOf: path), forged)
    }

    func testMalformedConfigurationIsNotHiddenByRouting() throws {
        let f = try fixture()
        let workspace = try CodexSharedWorkspace.bind(f.home)
        var bad = source(f)
        bad.argumentsText = "--user-data-dir=/one --user-data-dir=/two"
        XCTAssertThrowsError(try workspace.project(bad))
        bad.argumentsText = "'unclosed"
        XCTAssertThrowsError(try workspace.project(bad))
        bad.argumentsText = ""
        bad.environmentText = "INVALID LINE"
        XCTAssertThrowsError(try workspace.project(bad))
    }

    func testPersistenceRejectsStaleWritersAndMixedCopyPoliciesAndKeepsClaudeSetting() throws {
        let f = try fixture()
        let receipts = try XCTUnwrap(f.store.sharedHistoryStore)
        let claude = UUID()
        try receipts.setIncludesAllAccounts(true, applicationID: claude, expected: false)
        try enable(f)
        let current = try f.store.codexSharedWorkspace(f.app)
        XCTAssertThrowsError(try receipts.setCodexWorkspace(nil, applicationID: f.app.storageID, expected: nil))
        XCTAssertEqual(try f.store.codexSharedWorkspace(f.app), current)
        let group = SharedHistoryGroup(applicationStorageID: f.app.storageID, provider: "codex",
            profileStorageIDs: f.app.profiles.map(\.storageID), rootPaths:
                Dictionary(uniqueKeysWithValues: f.app.profiles.map { ($0.storageID.uuidString, "/synthetic/\($0.storageID)") }))
        XCTAssertThrowsError(try receipts.replace(nil, with: group))
        XCTAssertTrue(try receipts.includesAllAccounts(applicationID: claude))
        try receipts.setCodexWorkspace(nil, applicationID: f.app.storageID, expected: current)
        try receipts.replace(nil, with: group)
        XCTAssertThrowsError(try enable(f))
        XCTAssertTrue(try receipts.includesAllAccounts(applicationID: claude))
    }

    func testCorruptReceiptBlocksCodexLaunchAndCannotBeResetByToggle() throws {
        let f = try fixture()
        try enable(f)
        let receipt = try XCTUnwrap(f.store.libraryPrimaryURL).deletingLastPathComponent().appendingPathComponent("shared-history.json")
        let bytes = Data("{corrupt".utf8)
        try bytes.write(to: receipt)
        XCTAssertTrue(source(f).codexSharedWorkspaceInvalid)
        XCTAssertThrowsError(try f.store.setCodexSharedWorkspace(false, application: f.app, expected: nil))
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
    }
}
