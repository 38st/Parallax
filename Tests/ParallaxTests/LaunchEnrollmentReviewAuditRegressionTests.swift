import Foundation
import XCTest
@testable import Parallax

final class LaunchEnrollmentReviewAuditRegressionTests: XCTestCase {
    func testPreparerChecksEnrollmentBeforeCreatingMissingBaseRoot() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let base = f.root.appendingPathComponent("custom-mount/missing")
        let enrollment = try StorageVolumeEnrollmentStore(applicationSupportURL: f.root, isVolumeMounted: { _ in false })
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem(), enrollmentStore: enrollment)
        let paths = try resolver.resolve(baseRootURL: base, applicationStorageID: f.application.storageID, profileStorageID: UUID())
        try enrollment.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: base,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        XCTAssertThrowsError(try LaunchManagedDirectoryPreparer(pathResolver: resolver).prepare(
            ManagedLaunchDirectoryPreparationPlan(isolation: LaunchIsolationAnalysis(userData: .managed(paths.userData.url), codexHome: nil), effectiveAssignments: [], managedPaths: paths), managedPaths: paths)) {
            XCTAssertEqual(($0 as? ManagedPathError)?.code, .baseRootUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    @MainActor
    func testLibraryCompilerAndHealthUseEnrollmentDiagnostics() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let bundle = try ValidApplicationBundleFixture.create(in: f.root)
        var application = f.application
        application.appPath = bundle.url.path
        application.bundleIdentifier = bundle.bundleIdentifier
        _ = try f.repository.save([application], expectedVersion: f.version)
        let store = LibraryStore(repository: f.repository, profileActivityRegistry: f.registry)
        let profile = try XCTUnwrap(application.profiles.first)
        let source = LaunchConfigurationSource(requestID: UUID(), applicationID: application.id,
            applicationStorageID: application.storageID, profileID: profile.id, profileStorageID: profile.storageID,
            configurationRevision: 1, applicationURL: bundle.url, expectedBundleIdentifier: bundle.bundleIdentifier,
            configuredBaseRoot: f.source.path, argumentsText: "", environmentText: "",
            isolationOwnership: profile.isolationOwnership, childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [])
        try f.coordinator.enrollmentStore.recordVerifiedRoot(applicationStorageID: application.storageID, baseRoot: f.source,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        try FileManager.default.removeItem(at: f.source)
        let analysis = await store.launchConfigurationCompiler.analyze(source)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == .invalidManagedPath })
        XCTAssertThrowsError(try store.launchHealthService.pathResolver.resolve(baseRootURL: f.source,
            applicationStorageID: application.storageID, profileStorageID: profile.storageID))
        XCTAssertTrue(store.pathResolver.enrollmentStore === store.profileDataTransactions?.enrollmentStore)
        XCTAssertTrue(store.pathResolver.enrollmentStore === store.storageRelocationCoordinator?.enrollmentStore)
    }
}
