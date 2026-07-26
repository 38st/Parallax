import Foundation
import XCTest
@testable import Parallax

final class LaunchHealthServiceTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-LAUNCH-009-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testValidApplicationBundleReportsCanonicalIdentityAndExecutable() throws {
        let fixture = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory
        )
        let fileSystem = HealthRecordingFileSystem()
        let service = LaunchHealthService(fileSystem: fileSystem)
        let input = ApplicationHealthInput(
            applicationID: UUID(),
            applicationURL: fixture.url,
            expectedBundleIdentifier: fixture.bundleIdentifier
        )

        let report = service.inspectApplication(input)
        let canonicalFixtureURL = try LocalFileSystem()
            .canonicalURL(for: fixture.url)

        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.bundleIdentifier, fixture.bundleIdentifier)
        XCTAssertEqual(report.canonicalApplicationURL, canonicalFixtureURL)
        XCTAssertEqual(
            report.executableURL,
            canonicalFixtureURL.appendingPathComponent(
                "Contents/MacOS/\(fixture.executableName)"
            )
        )
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testApplicationMustBeAbsoluteAppDirectoryNotRegularFile() throws {
        let regularFile = temporaryDirectory.appendingPathComponent("Fake.app")
        try Data("not-an-app".utf8).write(to: regularFile)
        let service = LaunchHealthService()

        let report = service.inspectApplication(
            ApplicationHealthInput(
                applicationID: UUID(),
                applicationURL: regularFile,
                expectedBundleIdentifier: nil
            )
        )

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.code == .applicationNotDirectory })
    }

    func testApplicationBundleValidatesPlistExpectedIdentityAndExecutable() throws {
        let fixture = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            bundleIdentifier: "com.example.actual"
        )
        let service = LaunchHealthService()
        let mismatch = service.inspectApplication(
            ApplicationHealthInput(
                applicationID: UUID(),
                applicationURL: fixture.url,
                expectedBundleIdentifier: "com.example.expected"
            )
        )
        XCTAssertTrue(mismatch.issues.contains { $0.code == .bundleIdentifierMismatch })

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.url
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(fixture.executableName)
                .path
        )
        let notExecutable = service.inspectApplication(
            ApplicationHealthInput(
                applicationID: UUID(),
                applicationURL: fixture.url,
                expectedBundleIdentifier: fixture.bundleIdentifier
            )
        )
        XCTAssertTrue(notExecutable.issues.contains { $0.code == .executableNotRunnable })

        try FileManager.default.removeItem(
            at: fixture.url.appendingPathComponent("Contents/Info.plist")
        )
        let missingPlist = service.inspectApplication(
            ApplicationHealthInput(
                applicationID: UUID(),
                applicationURL: fixture.url,
                expectedBundleIdentifier: nil
            )
        )
        XCTAssertTrue(missingPlist.issues.contains { $0.code == .missingInfoPlist })
    }

    func testMissingManagedTargetsUseWritableAncestorWithoutCreatingAnything() throws {
        let fileSystem = HealthRecordingFileSystem()
        let service = LaunchHealthService(fileSystem: fileSystem)
        let input = makeProfileInput()

        let report = service.inspectProfiles([input]).first

        let profileReport = try XCTUnwrap(report)
        XCTAssertTrue(profileReport.isHealthy)
        XCTAssertTrue(
            profileReport.paths.allSatisfy {
                $0.state == .missingCreatable || $0.state == .existingDirectory
            }
        )
        XCTAssertTrue(fileSystem.mutations.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent(".parallax")
                    .path
            )
        )
    }

    func testManagedRegularFileTargetIsUnhealthyAndHealthPerformsNoWrites() throws {
        let fileSystem = HealthRecordingFileSystem()
        let input = makeProfileInput()
        let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
            configuredBaseRoot: input.configuredBaseRoot,
            applicationStorageID: input.applicationStorageID,
            profileStorageID: input.profileStorageID
        )
        try FileManager.default.createDirectory(
            at: resolved.profileRoot.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("wrong-kind".utf8).write(to: resolved.profileRoot.url)
        fileSystem.resetMutations()

        let report = try XCTUnwrap(
            LaunchHealthService(fileSystem: fileSystem)
                .inspectProfiles([input])
                .first
        )

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.code == .managedPathInvalid })
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testMissingManagedTargetRequiresWritableExistingAncestor() throws {
        let fileSystem = HealthRecordingFileSystem()
        let report = try XCTUnwrap(
            LaunchHealthService(
                fileSystem: fileSystem,
                writeAccess: NeverWritablePathChecker()
            )
            .inspectProfiles([makeProfileInput()])
            .first
        )

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(
            report.paths.contains { $0.state == .missingUnwritable }
        )
        XCTAssertTrue(report.issues.contains { $0.code == .noWritableAncestor })
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    func testManagedNamespaceSymlinkEscapeIsRejectedWithoutMutation() throws {
        let fileSystem = HealthRecordingFileSystem()
        let input = makeProfileInput()
        let outside = temporaryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Parallax-LAUNCH-009-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        let namespace = temporaryDirectory.appendingPathComponent(".parallax")
        try FileManager.default.createSymbolicLink(
            at: namespace,
            withDestinationURL: outside
        )
        fileSystem.resetMutations()

        let report = try XCTUnwrap(
            LaunchHealthService(fileSystem: fileSystem)
                .inspectProfiles([input])
                .first
        )

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.code == .managedPathInvalid })
        XCTAssertTrue(fileSystem.mutations.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            []
        )
    }

    func testExternalPathMustBeAbsoluteDirectoryWithWritableAncestor() throws {
        let service = LaunchHealthService()
        var input = makeProfileInput()
        input.isolationPaths = [
            ProfileIsolationHealthInput(
                role: .externalCodexHome,
                source: .external("relative/path")
            )
        ]

        let relative = try XCTUnwrap(
            service.inspectProfiles([input]).first
        )
        XCTAssertTrue(relative.issues.contains { $0.code == .externalPathInvalid })

        let file = temporaryDirectory.appendingPathComponent("external-file")
        try Data("wrong-kind".utf8).write(to: file)
        input.isolationPaths = [
            ProfileIsolationHealthInput(
                role: .externalCodexHome,
                source: .external(file.path)
            )
        ]
        let regularFile = try XCTUnwrap(
            service.inspectProfiles([input]).first
        )
        XCTAssertTrue(regularFile.issues.contains { $0.code == .externalPathInvalid })
    }

    func testActiveProfileIsReportedByStorageIdentity() throws {
        let input = makeProfileInput()
        let activity = HealthActivityProvider(
            active: [
                ProfileActivityIdentity(
                    applicationID: input.applicationID,
                    applicationStorageID: input.applicationStorageID,
                    profileID: input.profileID,
                    profileStorageID: input.profileStorageID
                )
            ]
        )

        let report = try XCTUnwrap(
            LaunchHealthService(activityProvider: activity)
                .inspectProfiles([input])
                .first
        )

        XCTAssertTrue(report.isActive)
        XCTAssertTrue(report.issues.contains { $0.code == .profileActive })
    }

    func testSymlinkAliasedExternalPathsCollideAcrossProfiles() throws {
        let external = temporaryDirectory.appendingPathComponent(
            "External",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        let alias = temporaryDirectory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: external
        )
        var first = makeProfileInput()
        var second = makeProfileInput()
        second.profileID = UUID()
        second.profileStorageID = UUID()
        first.isolationPaths = [
            ProfileIsolationHealthInput(
                role: .externalUserData,
                source: .external(external.path)
            )
        ]
        second.isolationPaths = [
            ProfileIsolationHealthInput(
                role: .externalUserData,
                source: .external(alias.path)
            )
        ]

        let reports = LaunchHealthService().inspectProfiles([first, second])

        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(
            reports.allSatisfy {
                $0.issues.contains { $0.code == .canonicalPathCollision }
            }
        )
    }

    func testInvalidManagedRootDoesNotSuppressExternalCollisionChecks() throws {
        let external = temporaryDirectory.appendingPathComponent(
            "SharedExternal",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        var first = makeProfileInput()
        var second = makeProfileInput()
        first = ProfileHealthInput(
            applicationID: first.applicationID,
            profileID: first.profileID,
            applicationStorageID: first.applicationStorageID,
            profileStorageID: first.profileStorageID,
            configuredBaseRoot: "relative",
            isolationPaths: [
                ProfileIsolationHealthInput(
                    role: .externalUserData,
                    source: .external(external.path)
                )
            ]
        )
        second = ProfileHealthInput(
            applicationID: second.applicationID,
            profileID: UUID(),
            applicationStorageID: second.applicationStorageID,
            profileStorageID: UUID(),
            configuredBaseRoot: "relative",
            isolationPaths: [
                ProfileIsolationHealthInput(
                    role: .externalUserData,
                    source: .external(external.path)
                )
            ]
        )

        let reports = LaunchHealthService().inspectProfiles([first, second])

        XCTAssertTrue(
            reports.allSatisfy {
                $0.issues.contains { $0.code == .managedPathInvalid }
            }
        )
        XCTAssertTrue(
            reports.allSatisfy {
                $0.issues.contains { $0.code == .canonicalPathCollision }
            }
        )
        XCTAssertTrue(
            reports.allSatisfy {
                $0.paths.contains { $0.role == .externalUserData }
            }
        )
    }

    func testFileIdentityCollisionIsDetectedEvenWithDistinctCanonicalPaths() throws {
        let firstExternal = temporaryDirectory.appendingPathComponent("First")
        let secondExternal = temporaryDirectory.appendingPathComponent("Second")
        try FileManager.default.createDirectory(
            at: firstExternal,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondExternal,
            withIntermediateDirectories: true
        )
        let sharedIdentity = FileSystemObjectIdentity(
            volumeID: 42,
            fileID: 99
        )
        let fileSystem = HealthRecordingFileSystem(
            identityOverrides: [
                firstExternal.standardizedFileURL: sharedIdentity,
                secondExternal.standardizedFileURL: sharedIdentity,
            ]
        )
        var first = makeProfileInput()
        var second = makeProfileInput()
        second.profileID = UUID()
        second.profileStorageID = UUID()
        first.isolationPaths = [
            ProfileIsolationHealthInput(
                role: .externalUserData,
                source: .external(firstExternal.path)
            )
        ]
        second.isolationPaths = [
            ProfileIsolationHealthInput(
                role: .externalUserData,
                source: .external(secondExternal.path)
            )
        ]

        let reports = LaunchHealthService(fileSystem: fileSystem)
            .inspectProfiles([first, second])

        XCTAssertTrue(
            reports.allSatisfy {
                $0.issues.contains { $0.code == .fileIdentityCollision }
            }
        )
        XCTAssertTrue(fileSystem.mutations.isEmpty)
    }

    private func makeProfileInput() -> ProfileHealthInput {
        ProfileHealthInput(
            applicationID: UUID(),
            profileID: UUID(),
            applicationStorageID: UUID(),
            profileStorageID: UUID(),
            configuredBaseRoot: temporaryDirectory.path,
            isolationPaths: [
                ProfileIsolationHealthInput(
                    role: .managedUserData,
                    source: .managedUserData
                ),
                ProfileIsolationHealthInput(
                    role: .managedCodexHome,
                    source: .managedCodexHome
                ),
            ]
        )
    }
}

private final class HealthActivityProvider:
    ProfileHealthActivityProviding,
    @unchecked Sendable
{
    private let active: Set<ProfileActivityIdentity>

    init(active: Set<ProfileActivityIdentity>) {
        self.active = active
    }

    func isStorageActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> Bool {
        active.contains {
            $0.applicationStorageID == applicationStorageID
                && $0.profileStorageID == profileStorageID
        }
    }
}

private final class HealthRecordingFileSystem: FileSystem, @unchecked Sendable {
    private let underlying = LocalFileSystem()
    private let identityOverrides: [URL: FileSystemObjectIdentity]
    private(set) var mutations: [String] = []

    init(identityOverrides: [URL: FileSystemObjectIdentity] = [:]) {
        self.identityOverrides = identityOverrides
    }

    func resetMutations() {
        mutations.removeAll()
    }

    func fileExists(at url: URL) -> Bool {
        underlying.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        var attributes = try underlying.attributesOfItem(at: url)
        if let identity = identityOverrides[url.standardizedFileURL] {
            attributes.identity = identity
        }
        return attributes
    }

    func canonicalURL(for url: URL) throws -> URL {
        try underlying.canonicalURL(for: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        mutations.append("createDirectory")
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        mutations.append("copyItem")
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        mutations.append("moveItem")
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        mutations.append("removeItem")
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try underlying.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try underlying.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        mutations.append("writeData")
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        mutations.append("writeDataAtomically")
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        mutations.append("replaceItem")
        try underlying.replaceItem(at: destinationURL, withItemAt: sourceURL)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        mutations.append("setPOSIXPermissions")
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        mutations.append("synchronize")
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }
}

private struct NeverWritablePathChecker: PathWriteAccessChecking {
    func isWritable(at url: URL) -> Bool {
        false
    }
}
