import Foundation
import XCTest

@testable import Parallax

@MainActor
final class CodexSpacesAuditRegressionTests: XCTestCase {
    func testEmptyOrBlockedSyncDoesNotSetLibraryError() throws {
        let (store, defaults, root, account) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.loadState = .loading
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(accounts: [], synchronizationDefaults: defaults), 0)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }), 0)
        XCTAssertNil(store.errorMessage)
    }

    func testRemovedCodexSpaceStaysRemovedAcrossStoreRestart() throws {
        let (store, defaults, root, account) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }), 1)
        let application = try XCTUnwrap(store.applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id
        XCTAssertTrue(store.remove(profile: profile, dataRemoval: .keep))
        let restarted = LibraryStore(persistence: store.persistence, settings: store.settings)
        XCTAssertEqual(
            restarted.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }), 0)
        XCTAssertEqual(restarted.applications.first?.profiles.count, 0)
        XCTAssertEqual(
            restarted.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults, recreateRemovedSpaces: true,
                codexHomeResolver: { _ in root }), 1)
    }

    func testExistingPreUpgradeSpaceIsRememberedBeforeRemoval() throws {
        let (store, defaults, root, account) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var application = try XCTUnwrap(store.applications.first)
        application.profiles = [
            LaunchProfile(name: "Existing", environmentText: "CODEX_HOME=\(root.path)")
        ]
        XCTAssertTrue(
            store.commit(
                [application], selectedApplicationID: application.id, selectedProfileID: nil))
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }), 0)
        XCTAssertTrue(
            store.remove(profile: try XCTUnwrap(application.profiles.first), dataRemoval: .keep))
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }), 0)
    }

    func testFailedCreationDoesNotPreventLaterSynchronization() throws {
        let (store, defaults, root, account) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try XCTUnwrap(store.persistence as? AuditCodexSpacePersistence)
        persistence.failSaves = true
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }
            ), 0)
        XCTAssertEqual(store.applications.first?.profiles.count, 0)
        XCTAssertNil(defaults.stringArray(forKey: "codex.account-spaces.v1"))
        persistence.failSaves = false
        XCTAssertEqual(
            store.synchronizeCodexAccountSpaces(
                accounts: [account], synchronizationDefaults: defaults,
                codexHomeResolver: { _ in root }
            ), 1)
    }

    func testSignedOutExistingSpaceIsAdoptedAndDeletedAccountReceiptsArePruned() throws {
        let (store, defaults, root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var account = original
        account.signInRequired = true
        var application = try XCTUnwrap(store.applications.first)
        application.profiles = [
            LaunchProfile(name: "Existing", environmentText: "CODEX_HOME=\(root.path)")
        ]
        XCTAssertTrue(
            store.commit([application], selectedApplicationID: nil, selectedProfileID: nil))
        store.synchronizeCodexAccountSpaces(
            accounts: [account], synchronizationDefaults: defaults, codexHomeResolver: { _ in root }
        )
        XCTAssertEqual(defaults.stringArray(forKey: "codex.account-spaces.v1")?.count, 1)
        store.synchronizeCodexAccountSpaces(
            accounts: [], synchronizationDefaults: defaults, codexHomeResolver: { _ in root })
        XCTAssertEqual(defaults.stringArray(forKey: "codex.account-spaces.v1"), [])
    }

    func testBlockedCreationDoesNotDiscardAdoptedReceipts() throws {
        let (store, defaults, root, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var application = try XCTUnwrap(store.applications.first)
        application.profiles = [
            LaunchProfile(name: "Existing", environmentText: "CODEX_HOME=\(root.path)")
        ]
        XCTAssertTrue(
            store.commit([application], selectedApplicationID: nil, selectedProfileID: nil))
        let second = TrackedAIAccount(
            id: UUID(), provider: .codex, label: "Second", email: "", planName: "", usagePercent: 0,
            resetsAt: .distantPast, lastCheckedAt: nil, isConnected: true, lifetimeTokens: nil)
        store.loadState = .loading
        store.synchronizeCodexAccountSpaces(
            accounts: [first, second], synchronizationDefaults: defaults,
            codexHomeResolver: { id in
                id == first.id ? root : root.appendingPathComponent("second")
            })
        XCTAssertEqual(
            defaults.stringArray(forKey: "codex.account-spaces.v1"),
            [application.storageID.uuidString + ":" + first.id.uuidString])
    }

    private func fixture() throws -> (LibraryStore, UserDefaults, URL, TrackedAIAccount) {
        let suite = "CodexSpacesAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = AppSettings(userDefaults: defaults)
        settings.defaultBaseStoragePath = root.path
        let application = ManagedApplication(
            displayName: "Codex", bundleIdentifier: "com.openai.codex",
            appPath: root.appendingPathComponent("Codex.app").path, preset: .codex,
            baseStoragePath: root.path, profiles: [])
        let store = LibraryStore(
            persistence: AuditCodexSpacePersistence([application]), settings: settings)
        let account = TrackedAIAccount(
            id: UUID(), provider: .codex, label: "Fixture", email: "test@example.com",
            planName: "Plus", usagePercent: 0, resetsAt: .distantPast, lastCheckedAt: .distantPast,
            isConnected: true, lifetimeTokens: nil)
        return (store, defaults, root, account)
    }
}

private final class AuditCodexSpacePersistence: LibraryPersisting {
    private var applications: [ManagedApplication]
    var failSaves = false
    init(_ applications: [ManagedApplication]) { self.applications = applications }
    func load() throws -> [ManagedApplication] { applications }
    func loadResult() throws -> LibraryLoadResult { .current(applications) }
    func save(_ applications: [ManagedApplication]) throws {
        if failSaves { throw CocoaError(.fileWriteUnknown) }
        self.applications = applications
    }
}
