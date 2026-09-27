import Foundation
import XCTest
@testable import Parallax

@MainActor
final class ProfileSecretAuditRegressionTests: XCTestCase {
    func fixture() throws -> (LibraryStore, ProfileAuditRepository, ProfileAuditSecretStore, LaunchProfile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-PROF-Secrets-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: "Synthetic")
        let app = ManagedApplication(displayName: "Synthetic", appPath: root.appendingPathComponent("Synthetic.app").path,
                                     baseStoragePath: root.path, profiles: [profile])
        let repository = ProfileAuditRepository(base: LibraryRepository(applicationSupportURL: root))
        _ = try repository.save([app], expectedVersion: .missing, backupReason: nil)
        let secrets = ProfileAuditSecretStore()
        let store = LibraryStore(repository: repository, profileActivityRegistry: ProfileActivityRegistry(),
                                 launcher: AuditNoopLauncher(), secretStore: secrets, settings: AppSettings())
        return (store, repository, secrets, profile)
    }

    func testUncertainSecretPublicationRetainsNewKeychainItem() async throws {
        for state in [LibraryCommitPrimaryState.target, .neither] {
            let (store, repository, secrets, profile) = try fixture()
            repository.failNextSave(state)
            let result = await store.storeKeychainSecret("synthetic", environmentKey: "TOKEN", for: profile)
            XCTAssertFalse(result)
            let removed = await secrets.removed
            let stored = await secrets.stored
            XCTAssertEqual(stored.count, 1)
            XCTAssertTrue(removed.isEmpty, "A target or unknown primary can still reference the item")
        }
    }

    func testProvenPriorSecretPublicationDiscardsNewItem() async throws {
        let (store, repository, secrets, profile) = try fixture()
        repository.failNextSave(.prior)
        let result = await store.storeKeychainSecret("synthetic", environmentKey: "TOKEN", for: profile)
        XCTAssertFalse(result)
        let removed = await secrets.removed
        let stored = await secrets.stored
        XCTAssertEqual(removed, stored)
    }

    func testFailedSecretDeletionRestoresPersistedReference() async throws {
        let (store, _, secrets, profile) = try fixture()
        let result = await store.storeKeychainSecret("synthetic", environmentKey: "TOKEN", for: profile)
        XCTAssertTrue(result)
        let saved = try XCTUnwrap(store.applications.first?.profiles.first)
        await secrets.failRemoval()
        let removed = await store.removeKeychainSecret(environmentKey: "TOKEN", for: saved)
        XCTAssertFalse(removed)
        XCTAssertEqual(store.applications.first?.profiles.first?.environmentText, saved.environmentText)
        XCTAssertNotNil(store.errorMessage)
    }
}

actor ProfileAuditSecretStore: SecretStoring {
    private(set) var stored: [EnvironmentSecretReference] = []
    private(set) var removed: [EnvironmentSecretReference] = []
    private var removalFails = false
    private var removalHook: (@MainActor @Sendable () -> Void)?
    func setRemovalHook(_ hook: @escaping @MainActor @Sendable () -> Void) { removalHook = hook }
    func failRemoval() { removalFails = true }
    func store(_ value: SecretValue, for reference: EnvironmentSecretReference) async throws { stored.append(reference) }
    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue { SecretValue("synthetic") }
    func remove(_ reference: EnvironmentSecretReference) async throws {
        if let removalHook { await removalHook() }
        if removalFails { throw CocoaError(.fileWriteUnknown) }
        removed.append(reference)
    }
}

final class ProfileAuditRepository: LibraryRepositoryPersisting, @unchecked Sendable {
    let base: LibraryRepository
    private let lock = NSLock()
    private var failure: LibraryCommitPrimaryState?
    private var readsFail = false
    init(base: LibraryRepository) { self.base = base }
    var persistence: any LibraryRepositoryPersistence { base.persistence }
    func failNextSave(_ state: LibraryCommitPrimaryState) { lock.withLock { failure = state } }
    func load() -> LibraryRepositoryLoadOutcome {
        if lock.withLock({ readsFail }) {
            return .recoveryRequired(.init(originalBytes: nil, error: CocoaError(.fileReadUnknown)))
        }
        return base.load()
    }
    func prepare(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken) throws -> PreparedLibraryCommit {
        try base.prepare(applications, expectedVersion: expectedVersion)
    }
    func tryWithExclusiveAccess<T>(_ body: (LibraryExclusiveAccess) throws -> T) throws -> LibraryExclusiveAccessResult<T> {
        try base.tryWithExclusiveAccess(body)
    }
    func withExclusiveMutation<T>(expectedVersion: LibraryVersionToken,
                                  _ body: (LibraryMutationCommitCapability) throws -> T) throws -> T {
        try base.withExclusiveMutation(expectedVersion: expectedVersion, body)
    }
    func save(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken,
              backupReason: LibraryBackupReason?) throws -> LibraryRepositorySnapshot {
        let state = lock.withLock { () -> LibraryCommitPrimaryState? in
            defer { failure = nil }
            return failure
        }
        if let state {
            if state != .prior {
                _ = try base.save(applications, expectedVersion: expectedVersion, backupReason: backupReason)
                lock.withLock { readsFail = true }
            }
            throw LibraryRepositoryError.commitFailed(state: state,
                failure: LibraryPersistenceFailure(originalBytes: nil, error: CocoaError(.fileWriteUnknown)))
        }
        return try base.save(applications, expectedVersion: expectedVersion, backupReason: backupReason)
    }
}
