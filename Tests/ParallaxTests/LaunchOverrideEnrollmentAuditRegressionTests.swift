import Foundation
import XCTest
@testable import Parallax

final class LaunchOverrideEnrollmentAuditRegressionTests: XCTestCase {
    func testDiagnosticOverrideCannotCreateRootOnAnUnpluggedDrive() async throws {
        try await checkOverride(active: false)
    }

    func testConcurrentOverrideCannotCreateRootOnAnUnpluggedDrive() async throws {
        try await checkOverride(active: true)
    }

    private func checkOverride(active: Bool) async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let bundle = try ValidApplicationBundleFixture.create(in: f.root)
        let profile = try XCTUnwrap(f.application.profiles.first)
        let source = makeSource(f, bundle: bundle, profile: profile,
            arguments: profile.argumentsText + (active ? "" : " --label 'unfinished"))
        try FileManager.default.removeItem(at: f.source)
        let enrollment = try StorageVolumeEnrollmentStore(applicationSupportURL: f.root, isVolumeMounted: { _ in false })
        let compiler = LaunchConfigurationCompiler(
            pathResolver: ManagedPathResolver(fileSystem: LocalFileSystem(), enrollmentStore: enrollment),
            activityProvider: EnrollmentActivity(active: active), secretResolver: EnrollmentNoSecrets(),
            preparationHook: {
                try enrollment.recordVerifiedRoot(applicationStorageID: source.applicationStorageID, baseRoot: f.source,
                    volumeUUID: "00000000-0000-0000-0000-000000000099")
            })
        let analysis = await compiler.analyze(source)
        let blocking = analysis.diagnostics.filter { $0.severity == .error }
        XCTAssertFalse(blocking.isEmpty)
        XCTAssertTrue(blocking.allSatisfy { $0.isOverridable || (active && $0.code == .profileHealth(.profileActive)) })
        let override = LaunchDiagnosticOverride(requestID: source.requestID,
            configurationFingerprint: analysis.configurationFingerprint, allowsActiveProfileRisk: active)
        do {
            _ = try await compiler.prepare(source, override: override)
            XCTFail("An override must not recreate unavailable storage")
        } catch {
            XCTAssertEqual((error as? ManagedPathError)?.code, .baseRootUnavailable)
        }
        XCTAssertFalse(f.exists(f.source))
    }

    @MainActor
    func testSuccessfulPreparationEnrollsCurrentConfiguredRoot() async throws {
        try await checkPreparationEnrollment(changeRoot: false)
    }

    @MainActor
    func testStalePreparationCannotReplaceNewerEnrollment() async throws {
        try await checkPreparationEnrollment(changeRoot: true)
    }

    @MainActor
    private func checkPreparationEnrollment(changeRoot: Bool) async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let bundle = try ValidApplicationBundleFixture.create(in: f.root)
        let profile = try XCTUnwrap(f.application.profiles.first)
        let source = makeSource(f, bundle: bundle, profile: profile, arguments: profile.argumentsText)
        let compiler = LaunchConfigurationCompiler(pathResolver: f.coordinator.pathResolver,
            secretResolver: EnrollmentNoSecrets(), preparationHook: {
                if changeRoot {
                    var application = f.application
                    application.baseStoragePath = f.destination.path
                    _ = try f.repository.save([application], expectedVersion: f.version)
                    try f.coordinator.enrollmentStore.enroll(applicationStorageID: application.storageID,
                        configuredBaseRoot: f.destination, canonicalBaseRoot: f.destination)
                }
            })
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, launchConfigurationCompiler: compiler)
        _ = try await store.launchConfigurationCompiler.prepare(source)
        XCTAssertEqual(try f.coordinator.enrollmentStore.record(applicationStorageID: f.application.storageID)?.baseRootPath,
            changeRoot ? f.destination.path : f.source.path)
    }

    private func makeSource(_ f: RelocationAuditFixture, bundle: ValidApplicationBundleFixture,
        profile: LaunchProfile, arguments: String) -> LaunchConfigurationSource {
        LaunchConfigurationSource(requestID: UUID(), applicationID: f.application.id,
            applicationStorageID: f.application.storageID, profileID: profile.id, profileStorageID: profile.storageID,
            configurationRevision: 1, applicationURL: bundle.url, expectedBundleIdentifier: bundle.bundleIdentifier,
            configuredBaseRoot: f.source.path, argumentsText: arguments, environmentText: "",
            isolationOwnership: profile.isolationOwnership, childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [])
    }
}

private struct EnrollmentActivity: ProfileHealthActivityProviding {
    let active: Bool
    func isStorageActive(applicationStorageID: UUID, profileStorageID: UUID) -> Bool { active }
}

private struct EnrollmentNoSecrets: SecretResolving {
    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue { throw SecretStoreError.missing(reference) }
}
