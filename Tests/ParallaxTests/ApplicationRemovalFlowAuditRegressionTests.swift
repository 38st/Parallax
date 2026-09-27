import Foundation
import XCTest
@testable import Parallax

final class ApplicationRemovalFlowAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationRemovalFlowAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor
    func testRemovalPreservesSurvivingSelectionAndClearsRemovedSelection() throws {
        for removeSelected in [true, false] {
            let fixture = try fixture()
            let selected = removeSelected ? fixture.app : fixture.other
            fixture.store.selectedApplicationID = selected.id
            fixture.store.selectedProfileID = selected.profiles[0].id
            fixture.store.beginApplicationRemoval(fixture.app)
            fixture.store.confirmApplicationRemoval()
            XCTAssertNil(fixture.store.errorMessage)
            XCTAssertEqual(fixture.store.selectedApplicationID, removeSelected ? nil : selected.id)
            XCTAssertEqual(fixture.store.selectedProfileID, removeSelected ? nil : selected.profiles[0].id)
        }
    }

    @MainActor
    func testDuplicateApplicationDoesNotSelectFirstProfile() throws {
        let fixture = try fixture()
        let bundle = root.appendingPathComponent("Duplicate.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var app = fixture.app
        app.appPath = bundle.path
        fixture.store.applications = [app]
        fixture.store.selectedApplicationID = app.id
        fixture.store.selectedProfileID = nil
        fixture.store.addApplication(at: bundle)
        XCTAssertNil(fixture.store.selectedProfileID)
    }

    @MainActor
    func testNewApplicationSelectsItsCreatedProfile() throws {
        let fixture = try fixture()
        fixture.store.settings.defaultBaseStoragePath = root.appendingPathComponent("NewStorage").path
        let bundle = root.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        fixture.store.addApplication(at: bundle)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.store.applications.count, 3)
        let created = try XCTUnwrap(fixture.store.applications.last)
        XCTAssertEqual(fixture.store.selectedApplicationID, created.id)
        XCTAssertEqual(fixture.store.selectedProfileID, created.profiles[0].id)
    }

    @MainActor
    func testRejectedActiveRemovalDoesNotCreateBackup() throws {
        let fixture = try fixture()
        let profile = fixture.app.profiles[0]
        let lease = try fixture.registry.acquire(identity: ProfileActivityIdentity(applicationID: fixture.app.id,
            applicationStorageID: fixture.app.storageID, profileID: profile.id, profileStorageID: profile.storageID), requestID: UUID())
        defer { lease.release() }
        fixture.store.beginApplicationRemoval(fixture.app, dataChoice: .delete)
        fixture.store.confirmApplicationRemoval()
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertTrue(try fixture.backups.inspectArtifacts().isEmpty)
    }

    @MainActor
    func testChangedTargetDoesNotCreateBackup() throws {
        let fixture = try fixture()
        fixture.store.beginApplicationRemoval(fixture.app)
        fixture.store.applications[0].displayName = "Changed after confirmation"
        fixture.store.confirmApplicationRemoval()
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertTrue(try fixture.backups.inspectArtifacts().isEmpty)
    }

    @MainActor
    func testAsyncConfirmationRechecksMutationAuthority() async throws {
        let fixture = try fixture()
        fixture.store.beginApplicationRemoval(fixture.app)
        fixture.store.loadState = .recoveryRequired(originalBytes: nil, message: "Synthetic recovery")
        await fixture.store.confirmApplicationRemovalAsync()
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
        XCTAssertEqual(snapshot.applications, [fixture.app, fixture.other])
        XCTAssertTrue(try fixture.backups.inspectArtifacts().isEmpty)
    }

    @MainActor
    func testExternalPathsExcludeContainedOverridesAndIncludeClaudeConfig() throws {
        let fixture = try fixture()
        var app = fixture.app
        var profile = app.profiles[0]
        let managed = try fixture.store.managedPaths(for: app, profile: profile).profileRoot.url
        profile.argumentsText = ShellWordsParser.quote("--user-data-dir=\(managed.appendingPathComponent("CustomData").path)")
        let external = root.appendingPathComponent("ExternalClaude").path
        profile.environmentText = "CLAUDE_CONFIG_DIR=\(external)"
        app.profiles = [profile]
        let targets = try fixture.store.applicationRemovalProfileTargets(app)
        XCTAssertEqual(targets[0].externalPaths.map(\.declaredPath), [external])
    }

    @MainActor
    func testInvalidClaudeConfigurationDoesNotBlockRemovalTargetReview() throws {
        let fixture = try fixture()
        var app = fixture.app
        app.profiles[0].environmentText = "CLAUDE_CONFIG_DIR=relative"
        XCTAssertEqual(try fixture.store.applicationRemovalProfileTargets(app).count, 2)
    }

    @MainActor
    func testMixedExistingAndMissingRootsUseSameCanonicalBase() throws {
        let fixture = try fixture(aliasBase: true)
        let paths = try fixture.store.managedPaths(for: fixture.app, profile: fixture.app.profiles[0])
        try FileManager.default.createDirectory(at: paths.profileRoot.url, withIntermediateDirectories: true)
        let targets = try fixture.store.applicationRemovalProfileTargets(fixture.app)
        let bases = targets.map { target in
            var base = target.managedProfileRoot.canonicalURL
            for _ in 0..<5 { base.deleteLastPathComponent() }
            return base.path
        }
        XCTAssertEqual(Set(bases).count, 1, bases.joined(separator: "\n"))
        fixture.store.beginApplicationRemoval(fixture.app)
        fixture.store.confirmApplicationRemoval()
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertFalse(fixture.store.applications.contains(where: { $0.id == fixture.app.id }))
    }

    @MainActor
    func testRemovalReservesEveryProfileThroughCommit() async throws {
        let registry = ProfileActivityRegistry()
        let identities = FlowAuditIdentities()
        let fixture = try fixture(registry: registry, boundary: { boundary in
            guard case .beforeEffect(.commitMetadata) = boundary else { return }
            for identity in identities.values {
                XCTAssertTrue(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                    profileStorageID: identity.profileStorageID))
                XCTAssertThrowsError(try registry.acquire(identity: identity, requestID: UUID()))
            }
        })
        identities.set(fixture.app.profiles.map { ProfileActivityIdentity(applicationID: fixture.app.id,
            applicationStorageID: fixture.app.storageID, profileID: $0.id, profileStorageID: $0.storageID) })
        fixture.store.beginApplicationRemoval(fixture.app)
        await fixture.store.confirmApplicationRemovalAsync()
        XCTAssertNil(fixture.store.errorMessage)
        for identity in identities.values {
            XCTAssertFalse(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                profileStorageID: identity.profileStorageID))
        }
    }

    @MainActor
    func testPostCommitFailureReloadsAndBroadcastsDurableMetadata() async throws {
        let fixture = try fixture(boundary: { boundary in
            if boundary == .afterEffectBeforeRecord(.commitMetadata) { throw FlowAuditError.injected }
        })
        fixture.store.beginApplicationRemoval(fixture.app)
        await fixture.store.confirmApplicationRemovalAsync()
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
        XCTAssertEqual(fixture.store.applications, snapshot.applications)
        XCTAssertEqual(fixture.store.libraryVersionToken, snapshot.versionToken)
        XCTAssertNotNil(fixture.broadcaster.latestEvent)
        XCTAssertNotNil(fixture.store.errorMessage)
    }

    @MainActor
    func testRollbackConflictImmediatelyBlocksFurtherStoreMutations() throws {
        let paths = FlowAuditPaths()
        let fixture = try fixture(boundary: { boundary in
            guard case .afterEffectBeforeRecord(.stageProfile(let profileID, 0)) = boundary,
                  let source = paths.url(for: profileID) else { return }
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: source.appendingPathComponent("replacement.txt"))
            throw FlowAuditError.injected
        })
        for profile in fixture.app.profiles {
            let source = try fixture.store.managedPaths(for: fixture.app, profile: profile).profileRoot.url
            paths.set(source, for: profile.storageID)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
        }
        fixture.store.beginApplicationRemoval(fixture.app, dataChoice: .delete)
        fixture.store.confirmApplicationRemoval()
        guard case .recoveryRequired = fixture.store.loadState else {
            return XCTFail("A pending rollback must block further mutations")
        }
        XCTAssertEqual(fixture.store.errorMessage,
            ApplicationRemovalTransactionError(code: .conflictingManagedData).localizedDescription)
        XCTAssertFalse(fixture.store.canMutateLibrary())
        XCTAssertNotNil(fixture.broadcaster.latestEvent)
        XCTAssertEqual(try fixture.store.applicationRemovalTransactions?.pendingTransactions().count, 1)
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
        XCTAssertEqual(snapshot.applications, [fixture.app, fixture.other])
    }

    @MainActor
    func fixture(aliasBase: Bool = false, registry: ProfileActivityRegistry = ProfileActivityRegistry(),
        boundary: (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)? = nil,
        backupHook: ((Data) throws -> LibraryRecoveryArtifact)? = nil) throws -> FlowAuditFixture {
        let workspace = root.appendingPathComponent(UUID().uuidString)
        let canonicalBase = workspace.appendingPathComponent("Managed")
        try FileManager.default.createDirectory(at: canonicalBase, withIntermediateDirectories: true)
        let base = aliasBase ? URL(fileURLWithPath: canonicalBase.path.replacingOccurrences(of: "/private/var/", with: "/var/")) : canonicalBase
        let app = ManagedApplication(displayName: "Fixture", appPath: "/Applications/Fixture.app", preset: .chromium,
            baseStoragePath: base.path, profiles: [LaunchProfile(name: "One"), LaunchProfile(name: "Two")])
        let other = ManagedApplication(displayName: "Other", appPath: "/Applications/Other.app", profiles: [LaunchProfile(name: "Other")])
        let repository = LibraryRepository(applicationSupportURL: workspace)
        _ = try repository.save([app, other], expectedVersion: .missing)
        let backups = LibraryBackupStore(recoveryRoot: workspace.appendingPathComponent("Backups"))
        let broadcaster = LibraryChangeBroadcaster()
        let store = LibraryStore(repository: repository, backupStore: backups,
            applicationRemovalTransactions: try ApplicationRemovalTransactionCoordinator(applicationSupportURL: workspace, transactionBoundary: boundary),
            applicationRemovalBackupHook: backupHook,
            profileActivityRegistry: registry, settings: AppSettings(), libraryChangeBroadcaster: broadcaster)
        return FlowAuditFixture(app: app, other: other, store: store, repository: repository, backups: backups, registry: registry, broadcaster: broadcaster)
    }
}

private enum FlowAuditError: Error { case injected }
private final class FlowAuditIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProfileActivityIdentity] = []
    var values: [ProfileActivityIdentity] { lock.withLock { storage } }
    func set(_ value: [ProfileActivityIdentity]) { lock.withLock { storage = value } }
}
struct FlowAuditFixture {
    let app: ManagedApplication
    let other: ManagedApplication
    let store: LibraryStore
    let repository: LibraryRepository
    let backups: LibraryBackupStore
    let registry: ProfileActivityRegistry
    let broadcaster: LibraryChangeBroadcaster
}

private final class FlowAuditPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: URL] = [:]
    func url(for id: UUID) -> URL? { lock.withLock { storage[id] } }
    func set(_ url: URL, for id: UUID) { lock.withLock { storage[id] = url } }
}
