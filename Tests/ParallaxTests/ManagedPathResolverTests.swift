import Foundation
import XCTest
@testable import Parallax

/// Regression contract for STOR-003 and STOR-004.
///
/// These tests intentionally describe the production API that the path resolver
/// implementation must provide:
///
/// - `ManagedPathResolver(fileSystem:)`
/// - `resolve(configuredBaseRoot:applicationStorageID:profileStorageID:)`
/// - `resolve(baseRootURL:applicationStorageID:profileStorageID:)`
/// - `resolveExternalPath(_:)`
/// - `revalidateForMutation(_:)`
/// - `ManagedStorageComponent(validating:)`
///
/// `ResolvedProfilePaths` exposes typed managed paths named `profileRoot`,
/// `userData`, `codexHome`, `archiveRoot`, and
/// `stagingRoot(transactionID:)`. A managed path exposes only its immutable
/// resolved `url`. Errors are `ManagedPathError` values with a stable `code`.
///
/// External isolation paths are deliberately a distinct type and cannot be
/// passed to `revalidateForMutation`, which accepts only managed mutation
/// capabilities.
final class ManagedPathResolverTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private let applicationStorageID = UUID(
        uuid: (
            0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x4a, 0xaa,
            0x8a, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa
        )
    )
    private let profileStorageID = UUID(
        uuid: (
            0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x4b, 0xbb,
            0x8b, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb
        )
    )

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-STOR-003-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testConfiguredBaseRootRejectsEmptyWhitespaceRelativeAndTildePaths() {
        let invalidRoots: [(String, ManagedPathError.Code)] = [
            ("", .emptyBaseRoot),
            (" \n\t ", .emptyBaseRoot),
            ("Profiles", .relativeBaseRoot),
            ("./Profiles", .relativeBaseRoot),
            ("../Profiles", .relativeBaseRoot),
            ("~/Profiles", .relativeBaseRoot),
        ]

        for (configuredRoot, expectedCode) in invalidRoots {
            assertResolutionFails(
                configuredBaseRoot: configuredRoot,
                code: expectedCode
            )
        }
    }

    func testConfiguredBaseRootRejectsExplicitDotAndDotDotComponents() {
        let parent = temporaryDirectory.deletingLastPathComponent().path
        let roots: [(String, ManagedPathError.Code)] = [
            ("\(temporaryDirectory.path)/./Profiles", .dotPathComponent),
            ("\(temporaryDirectory.path)/Profiles/../Other", .dotDotPathComponent),
            ("\(parent)/../\(temporaryDirectory.lastPathComponent)", .dotDotPathComponent),
        ]

        for (configuredRoot, expectedCode) in roots {
            assertResolutionFails(
                configuredBaseRoot: configuredRoot,
                code: expectedCode
            )
        }
    }

    func testURLBaseRootRejectsNonFileURL() {
        let resolver = makeResolver()
        guard let nonFileURL = URL(string: "https://example.invalid/parallax") else {
            return XCTFail("The static non-file URL fixture must be valid.")
        }

        XCTAssertThrowsError(
            try resolver.resolve(
                baseRootURL: nonFileURL,
                applicationStorageID: applicationStorageID,
                profileStorageID: profileStorageID
            )
        ) { error in
            XCTAssertEqual(managedPathError(error)?.code, .nonFileBaseRoot)
        }
    }

    func testExistingAbsoluteDirectoryRootResolves() throws {
        let paths = try resolve(in: temporaryDirectory)

        XCTAssertEqual(
            paths.profileRoot.url,
            temporaryDirectory
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(applicationStorageID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(profileStorageID.uuidString.lowercased(), isDirectory: true)
        )
    }

    func testMissingAbsoluteRootLeafResolvesFromNearestExistingAncestor() throws {
        let missingRoot = temporaryDirectory
            .appendingPathComponent("MountedProfiles", isDirectory: true)

        let paths = try resolve(in: missingRoot)

        XCTAssertEqual(
            paths.profileRoot.url.path,
            "\(missingRoot.path)/.parallax/Applications/"
                + "\(applicationStorageID.uuidString.lowercased())/Profiles/"
                + profileStorageID.uuidString.lowercased()
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))
    }

    func testRegularFileBaseRootIsRejected() throws {
        let fileRoot = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("sentinel".utf8).write(to: fileRoot)

        assertResolutionFails(
            configuredBaseRoot: fileRoot.path,
            code: .baseRootNotDirectory
        )
    }

    func testRegularFileIntermediateAncestorIsRejected() throws {
        let file = temporaryDirectory.appendingPathComponent("root-file")
        try Data("sentinel".utf8).write(to: file)
        let configuredRoot = file.appendingPathComponent("child", isDirectory: true)

        assertResolutionFails(
            configuredBaseRoot: configuredRoot.path,
            code: .ancestorNotDirectory
        )
    }

    func testExistingManagedIntermediateFileIsRejected() throws {
        try Data("sentinel".utf8).write(
            to: temporaryDirectory.appendingPathComponent(".parallax")
        )

        assertResolutionFails(
            configuredBaseRoot: temporaryDirectory.path,
            code: .ancestorNotDirectory
        )
    }

    func testExistingGeneratedIsolationFileIsRejected() throws {
        let profileRoot = expectedProfileRoot(in: temporaryDirectory)
        try FileManager.default.createDirectory(
            at: profileRoot,
            withIntermediateDirectories: true
        )
        try Data("sentinel".utf8).write(
            to: profileRoot.appendingPathComponent("UserData")
        )

        assertResolutionFails(
            configuredBaseRoot: temporaryDirectory.path,
            code: .targetNotDirectory
        )
    }

    func testGeneratedIsolationSymlinkEscapeIsRejected() throws {
        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                "Parallax-STOR-003-isolation-\(UUID().uuidString)",
                isDirectory: true
            )
        let profileRoot = expectedProfileRoot(in: temporaryDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: profileRoot.appendingPathComponent("CodexHome"),
            withDestinationURL: outside
        )

        assertResolutionFails(
            configuredBaseRoot: temporaryDirectory.path,
            code: .outsideManagedRoot
        )
    }

    func testDisconnectedBaseVolumeIsReportedAsUnavailableNotMissing() {
        let resolver = ManagedPathResolver(
            fileSystem: UnavailableCanonicalizationFileSystem()
        )

        XCTAssertThrowsError(
            try resolver.resolve(
                configuredBaseRoot: temporaryDirectory.path,
                applicationStorageID: applicationStorageID,
                profileStorageID: profileStorageID
            )
        ) { error in
            XCTAssertEqual(managedPathError(error)?.code, .baseRootUnavailable)
        }
    }

    func testCanonicalContainmentForFullyExistingManagedPath() throws {
        let expectedProfileRoot = expectedProfileRoot(in: temporaryDirectory)
        try FileManager.default.createDirectory(
            at: expectedProfileRoot,
            withIntermediateDirectories: true
        )

        let paths = try resolve(in: temporaryDirectory)
        let mutationURL = try makeResolver().revalidateForMutation(paths.profileRoot)

        XCTAssertEqual(paths.profileRoot.url, expectedProfileRoot)
        XCTAssertEqual(mutationURL, expectedProfileRoot)
    }

    func testCanonicalContainmentForPartiallyNonexistentManagedPath() throws {
        let applicationsRoot = temporaryDirectory
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationsRoot,
            withIntermediateDirectories: true
        )

        let paths = try resolve(in: temporaryDirectory)
        let mutationURL = try makeResolver().revalidateForMutation(paths.profileRoot)

        XCTAssertEqual(mutationURL, expectedProfileRoot(in: temporaryDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mutationURL.path))
    }

    func testSiblingPrefixCannotSatisfyCanonicalContainment() throws {
        let sibling = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                temporaryDirectory.lastPathComponent + "-sibling",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        let paths = try resolve(in: temporaryDirectory)
        let namespace = temporaryDirectory.appendingPathComponent(".parallax")
        try FileManager.default.createSymbolicLink(
            at: namespace,
            withDestinationURL: sibling
        )

        XCTAssertThrowsError(
            try makeResolver().revalidateForMutation(paths.profileRoot)
        ) { error in
            XCTAssertEqual(managedPathError(error)?.code, .outsideManagedRoot)
        }
    }

    func testSymlinkedNamespaceAncestorEscapingRootIsRejected() throws {
        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("Parallax-STOR-003-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent(".parallax"),
            withDestinationURL: outside
        )

        assertResolutionFails(
            configuredBaseRoot: temporaryDirectory.path,
            code: .outsideManagedRoot
        )
    }

    func testSymlinkedApplicationTargetEscapingRootIsRejected() throws {
        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("Parallax-STOR-003-target-\(UUID().uuidString)", isDirectory: true)
        let applicationParent = temporaryDirectory
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationParent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: applicationParent.appendingPathComponent(
                applicationStorageID.uuidString.lowercased()
            ),
            withDestinationURL: outside
        )

        assertResolutionFails(
            configuredBaseRoot: temporaryDirectory.path,
            code: .outsideManagedRoot
        )
    }

    func testMutationRevalidationDetectsSymlinkIntroducedAfterPreview() throws {
        let paths = try resolve(in: temporaryDirectory)
        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("Parallax-STOR-003-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent(".parallax"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try makeResolver().revalidateForMutation(paths.profileRoot)
        ) { error in
            XCTAssertEqual(managedPathError(error)?.code, .outsideManagedRoot)
        }
    }

    func testMutationRevalidationDetectsExistingRootIdentityReplacement() throws {
        let baseRoot = temporaryDirectory.appendingPathComponent("replaceable-root")
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        let paths = try resolve(in: baseRoot)
        try FileManager.default.removeItem(at: baseRoot)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try makeResolver().revalidateForMutation(paths.profileRoot)
        ) { error in
            XCTAssertEqual(managedPathError(error)?.code, .rootIdentityChanged)
        }
    }

    func testResolvedProfilePathsUseTypedV2NamespaceLayout() throws {
        let transactionID = UUID(
            uuid: (
                0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x4c, 0xcc,
                0x8c, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc
            )
        )
        let paths = try resolve(in: temporaryDirectory)

        XCTAssertEqual(paths.profileRoot.url, expectedProfileRoot(in: temporaryDirectory))
        XCTAssertEqual(
            paths.userData.url,
            expectedProfileRoot(in: temporaryDirectory)
                .appendingPathComponent("UserData", isDirectory: true)
        )
        XCTAssertEqual(
            paths.codexHome.url,
            expectedProfileRoot(in: temporaryDirectory)
                .appendingPathComponent("CodexHome", isDirectory: true)
        )
        XCTAssertEqual(
            paths.archiveRoot.url,
            temporaryDirectory
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent(applicationStorageID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(profileStorageID.uuidString.lowercased(), isDirectory: true)
        )
        XCTAssertEqual(
            try paths.stagingRoot(transactionID: transactionID).url,
            temporaryDirectory
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Transactions", isDirectory: true)
                .appendingPathComponent(transactionID.uuidString.lowercased(), isDirectory: true)
        )
    }

    func testGeneratedArchiveEntryRemainsAManagedMutationCapability() throws {
        let paths = try resolve(in: temporaryDirectory)
        let entry = paths.archiveEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            nonce: applicationStorageID
        )

        XCTAssertTrue(entry.url.path.hasPrefix(paths.archiveRoot.url.path + "/"))
        XCTAssertTrue((entry as Any) is ManagedMutationPath)
        XCTAssertEqual(
            try makeResolver().revalidateForMutation(entry),
            entry.url
        )
    }

    func testVisibleArchivesNameDoesNotInfluenceManagedStorage() throws {
        let visibleName = "Archives"
        let application = ManagedApplication(
            storageID: applicationStorageID,
            displayName: visibleName,
            appPath: "/Applications/Fixture.app",
            profiles: [
                LaunchProfile(
                    storageID: profileStorageID,
                    name: visibleName
                )
            ]
        )

        let paths = try makeResolver().resolve(
            configuredBaseRoot: temporaryDirectory.path,
            applicationStorageID: application.storageID,
            profileStorageID: application.profiles[0].storageID
        )

        XCTAssertEqual(paths.profileRoot.url, expectedProfileRoot(in: temporaryDirectory))
        XCTAssertNotEqual(paths.profileRoot.url, paths.archiveRoot.url)
        XCTAssertFalse(paths.profileRoot.url.pathComponents.contains(visibleName))
    }

    func testStorageComponentRejectsEmptyTraversalSeparatorsAndControls() {
        let invalidComponents = [
            "",
            ".",
            "..",
            "/",
            "\\",
            ":",
            "profile/name",
            "profile\\name",
            "profile:name",
            "line\nbreak",
            "tab\tname",
            "nul\u{0}name",
            "control\u{1f}",
        ]

        for component in invalidComponents {
            XCTAssertThrowsError(
                try ManagedStorageComponent(validating: component),
                "Expected component \(component.debugDescription) to be rejected."
            ) { error in
                XCTAssertEqual(managedPathError(error)?.code, .invalidStorageComponent)
            }
        }
    }

    func testStorageComponentRejectsReservedNamespacesCaseAndWidthInsensitively() {
        let reservedComponents = [
            ".parallax",
            ".PARALLAX",
            "Applications",
            "applications",
            "Profiles",
            "PROFILES",
            "Archives",
            "archives",
            "UserData",
            "userdata",
            "CodexHome",
            "codexhome",
            "Transactions",
            "transactions",
            "Ａｒｃｈｉｖｅｓ",
            "Ｔｒａｎｓａｃｔｉｏｎｓ",
        ]

        for component in reservedComponents {
            XCTAssertThrowsError(
                try ManagedStorageComponent(validating: component),
                "Expected reserved component \(component.debugDescription) to be rejected."
            ) { error in
                XCTAssertEqual(managedPathError(error)?.code, .reservedStorageComponent)
            }
        }
    }

    func testStorageComponentRejectsEquivalentUnicodeNormalizationForms() {
        let precomposed = "Årchives"
        let decomposed = precomposed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(precomposed.unicodeScalars.count, decomposed.unicodeScalars.count)

        for component in [precomposed, decomposed] {
            XCTAssertThrowsError(
                try ManagedStorageComponent(validating: component)
            ) { error in
                XCTAssertEqual(managedPathError(error)?.code, .invalidStorageComponent)
            }
        }
    }

    func testOnlyCanonicalLowercaseUUIDStorageComponentIsAccepted() throws {
        let canonical = applicationStorageID.uuidString.lowercased()

        XCTAssertEqual(
            try ManagedStorageComponent(validating: canonical).rawValue,
            canonical
        )
        for invalid in [
            applicationStorageID.uuidString.uppercased(),
            "{\(canonical)}",
            canonical.replacingOccurrences(of: "-", with: ""),
            "00000000-0000-0000-0000-000000000000/..",
        ] {
            XCTAssertThrowsError(
                try ManagedStorageComponent(validating: invalid)
            ) { error in
                XCTAssertEqual(managedPathError(error)?.code, .invalidStorageComponent)
            }
        }
    }

    func testExternalIsolationPathCannotBecomeManagedMutationCapability() throws {
        let externalURL = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("External-CODEX_HOME-\(UUID().uuidString)", isDirectory: true)
        let resolver = makeResolver()

        let external = try resolver.resolveExternalPath(externalURL.path)
        let canonicalParent = try LocalFileSystem().canonicalURL(
            for: externalURL.deletingLastPathComponent()
        )

        XCTAssertEqual(external.url, externalURL)
        XCTAssertEqual(external.requestedURL, externalURL)
        XCTAssertEqual(
            external.canonicalURL,
            canonicalParent.appendingPathComponent(
                externalURL.lastPathComponent,
                isDirectory: true
            )
        )
        XCTAssertFalse((external as Any) is ManagedMutationPath)
        // Compile-time security boundary: this must not compile if uncommented.
        // try resolver.revalidateForMutation(external)
    }

    func testExternalIsolationRetainsRequestedPathAndExposesCanonicalEvidence()
        throws
    {
        let target = temporaryDirectory.appendingPathComponent(
            "ExternalTarget",
            isDirectory: true
        )
        let alias = temporaryDirectory.appendingPathComponent(
            "ExternalAlias",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: target
        )

        let external = try makeResolver().resolveExternalPath(alias.path)

        XCTAssertEqual(external.requestedURL, alias.standardizedFileURL)
        XCTAssertEqual(external.url, alias.standardizedFileURL)
        XCTAssertEqual(
            external.canonicalURL,
            try LocalFileSystem().canonicalURL(for: target)
        )
    }

    func testPathPreviewAndRepeatedResolutionAreStable() throws {
        let resolver = makeResolver()
        let first = try resolver.resolve(
            configuredBaseRoot: temporaryDirectory.path,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
        let second = try resolver.resolve(
            configuredBaseRoot: temporaryDirectory.path,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.profileRoot.url, second.profileRoot.url)
        XCTAssertEqual(
            try resolver.revalidateForMutation(first.profileRoot),
            second.profileRoot.url
        )
    }

    private func makeResolver() -> ManagedPathResolver {
        ManagedPathResolver(fileSystem: LocalFileSystem())
    }

    private func resolve(in baseRoot: URL) throws -> ResolvedProfilePaths {
        try makeResolver().resolve(
            configuredBaseRoot: baseRoot.path,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
    }

    private func expectedProfileRoot(in baseRoot: URL) -> URL {
        baseRoot
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(applicationStorageID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profileStorageID.uuidString.lowercased(), isDirectory: true)
    }

    private func assertResolutionFails(
        configuredBaseRoot: String,
        code: ManagedPathError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try makeResolver().resolve(
                configuredBaseRoot: configuredBaseRoot,
                applicationStorageID: applicationStorageID,
                profileStorageID: profileStorageID
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                managedPathError(error)?.code,
                code,
                file: file,
                line: line
            )
        }
    }

    private func managedPathError(_ error: Error) -> ManagedPathError? {
        error as? ManagedPathError
    }
}

/// Models a configured volume disappearing while its root is being
/// canonicalized. A resolver must not downgrade this failure to an ordinary
/// missing leaf, because doing so could redirect a managed mutation to a local
/// mount-point directory.
private struct UnavailableCanonicalizationFileSystem: FileSystem {
    private let underlying = LocalFileSystem()

    func fileExists(at url: URL) -> Bool {
        underlying.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        try underlying.attributesOfItem(at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        throw CocoaError(.fileReadNoSuchFile)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try underlying.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try underlying.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        try underlying.replaceItem(at: destinationURL, withItemAt: sourceURL)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }
}
