import Foundation
import XCTest
@testable import Parallax

final class StorageIdentityTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var userDefaultsSuiteName = ""

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-STOR-001-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        userDefaultsSuiteName = "Parallax-STOR-001-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    @MainActor
    func testSameDisplayNameApplicationsResolveToDistinctPhysicalDirectories() throws {
        let firstProfile = LaunchProfile(name: "Personal")
        let secondProfile = LaunchProfile(name: "Personal")
        let firstApplication = makeApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser One.app",
            profiles: [firstProfile]
        )
        let secondApplication = makeApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser Two.app",
            profiles: [secondProfile]
        )
        let store = makeStore()

        let firstPath = store.profileFolderPath(
            for: firstApplication,
            profile: firstProfile
        )
        let secondPath = store.profileFolderPath(
            for: secondApplication,
            profile: secondProfile
        )

        XCTAssertNotEqual(
            volumeInsensitiveIdentity(firstPath),
            volumeInsensitiveIdentity(secondPath),
            "Application display names must not determine physical storage identity."
        )
        XCTAssertNotEqual(
            try storageID(in: firstApplication),
            try storageID(in: secondApplication)
        )
    }

    @MainActor
    func testSameProfileDisplayNamesResolveToDistinctPhysicalDirectories() {
        assertDistinctProfilePaths(
            LaunchProfile(name: "Work"),
            LaunchProfile(name: "Work")
        )
    }

    @MainActor
    func testCaseVariantProfileDisplayNamesResolveToDistinctPhysicalDirectories() {
        assertDistinctProfilePaths(
            LaunchProfile(name: "Work"),
            LaunchProfile(name: "work")
        )
    }

    @MainActor
    func testUnicodeNormalizationVariantProfileNamesResolveToDistinctPhysicalDirectories() {
        let precomposed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(
            precomposed.precomposedStringWithCanonicalMapping,
            decomposed.precomposedStringWithCanonicalMapping,
            "The test inputs must be canonically equivalent."
        )

        assertDistinctProfilePaths(
            LaunchProfile(name: precomposed),
            LaunchProfile(name: decomposed)
        )
    }

    @MainActor
    func testApplicationRenamePreservesStorageIdentityAndPhysicalDirectory() throws {
        let profile = LaunchProfile(name: "Personal")
        var application = makeApplication(
            displayName: "Original Name",
            profiles: [profile]
        )
        let store = makeStore()
        let originalStorageID = try storageID(in: application)
        let originalPath = store.profileFolderPath(for: application, profile: profile)

        application.displayName = "Renamed Application"

        XCTAssertEqual(try storageID(in: application), originalStorageID)
        XCTAssertEqual(
            volumeInsensitiveIdentity(
                store.profileFolderPath(for: application, profile: profile)
            ),
            volumeInsensitiveIdentity(originalPath)
        )
    }

    @MainActor
    func testProfileRenamePreservesStorageIdentityAndPhysicalDirectory() throws {
        var profile = LaunchProfile(name: "Original Name")
        let application = makeApplication(profiles: [profile])
        let store = makeStore()
        let originalStorageID = try storageID(in: profile)
        let originalPath = store.profileFolderPath(for: application, profile: profile)

        profile.name = "Renamed Profile"

        XCTAssertEqual(try storageID(in: profile), originalStorageID)
        XCTAssertEqual(
            volumeInsensitiveIdentity(
                store.profileFolderPath(for: application, profile: profile)
            ),
            volumeInsensitiveIdentity(originalPath)
        )
    }

    func testV2EncodingContainsUniqueOpaqueApplicationAndProfileStorageIDs() throws {
        let applications = [
            makeApplication(
                displayName: "Browser",
                appPath: "/Applications/Browser One.app",
                profiles: [
                    LaunchProfile(name: "Work"),
                    LaunchProfile(name: "Work")
                ]
            ),
            makeApplication(
                displayName: "Browser",
                appPath: "/Applications/Browser Two.app",
                profiles: [
                    LaunchProfile(name: "Work")
                ]
            )
        ]

        let object = try jsonObject(for: LibraryDocument(applications: applications))
        XCTAssertEqual(object["version"] as? Int, 2)
        let encodedApplications = try XCTUnwrap(object["applications"] as? [[String: Any]])
        let applicationStorageIDs = try encodedApplications.map(storageID(in:))
        let profileStorageIDs = try encodedApplications.flatMap { application -> [UUID] in
            let profiles = try XCTUnwrap(application["profiles"] as? [[String: Any]])
            return try profiles.map(storageID(in:))
        }

        XCTAssertEqual(Set(applicationStorageIDs).count, applications.count)
        XCTAssertEqual(
            Set(profileStorageIDs).count,
            applications.flatMap(\.profiles).count
        )
        XCTAssertTrue(
            Set(applicationStorageIDs).isDisjoint(with: Set(profileStorageIDs)),
            "Application and profile storage identities must share no component."
        )
    }

    func testGeneratedStorageComponentsContainNoSeparatorsDotsOrReservedTokens() throws {
        let application = makeApplication(
            displayName: "../Archives/Browser",
            profiles: [
                LaunchProfile(name: "."),
                LaunchProfile(name: ".."),
                LaunchProfile(name: "Archives"),
                LaunchProfile(name: ".transactions")
            ]
        )
        let object = try jsonObject(for: application)
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        let components = try [storageComponent(in: object)]
            + profiles.map(storageComponent(in:))

        let reserved = Set([
            "applications",
            "archives",
            "profiles",
            "transactions",
            ".transactions",
            ".",
            ".."
        ])
        for component in components {
            XCTAssertNotNil(UUID(uuidString: component))
            XCTAssertEqual(component, component.lowercased())
            XCTAssertFalse(component.contains("/"))
            XCTAssertFalse(component.contains("\\"))
            XCTAssertFalse(component.contains("."))
            XCTAssertFalse(
                reserved.contains(
                    component.precomposedStringWithCanonicalMapping.lowercased()
                )
            )
        }
    }

    func testDuplicateImportedApplicationUUIDIsRejected() throws {
        let duplicateID = UUID()
        let first = applicationObject(
            id: duplicateID,
            storageID: UUID(),
            profileObjects: [profileObject()]
        )
        let second = applicationObject(
            id: duplicateID,
            storageID: UUID(),
            profileObjects: [profileObject()]
        )

        try assertLibraryRejected(applications: [first, second])
    }

    func testDuplicateImportedApplicationStorageIdentityIsRejected() throws {
        let duplicateStorageID = UUID()
        let first = applicationObject(
            storageID: duplicateStorageID,
            profileObjects: [profileObject()]
        )
        let second = applicationObject(
            storageID: duplicateStorageID,
            profileObjects: [profileObject()]
        )

        try assertLibraryRejected(applications: [first, second])
    }

    func testDuplicateImportedProfileUUIDIsRejected() throws {
        let duplicateID = UUID()
        let application = applicationObject(
            profileObjects: [
                profileObject(id: duplicateID),
                profileObject(id: duplicateID)
            ]
        )

        try assertLibraryRejected(applications: [application])
    }

    func testDuplicateImportedProfileStorageIdentityIsRejected() throws {
        let duplicateStorageID = UUID()
        let application = applicationObject(
            profileObjects: [
                profileObject(storageID: duplicateStorageID),
                profileObject(storageID: duplicateStorageID)
            ]
        )

        try assertLibraryRejected(applications: [application])
    }

    func testCurrentV2RequiresLogicalAndStorageIdentities() throws {
        let completeProfile = profileObject()
        let completeApplication = applicationObject(profileObjects: [completeProfile])

        for missingApplicationKey in ["id", "storageID"] {
            var application = completeApplication
            application.removeValue(forKey: missingApplicationKey)
            try assertLibraryRejected(applications: [application])
        }

        for missingProfileKey in ["id", "storageID"] {
            var profile = completeProfile
            profile.removeValue(forKey: missingProfileKey)
            let application = applicationObject(profileObjects: [profile])
            try assertLibraryRejected(applications: [application])
        }
    }

    func testCurrentV2RejectsMalformedStorageIdentity() throws {
        var application = applicationObject(profileObjects: [profileObject()])
        application["storageID"] = "../Archives"
        try assertLibraryRejected(applications: [application])
    }

    func testPersistenceRejectsDuplicateIdentityBeforeWriting() throws {
        let duplicateStorageID = UUID()
        let profiles = [
            LaunchProfile(storageID: duplicateStorageID, name: "One"),
            LaunchProfile(storageID: duplicateStorageID, name: "Two")
        ]
        let persistence = LibraryPersistence(applicationSupportURL: temporaryDirectory)

        XCTAssertThrowsError(
            try persistence.save([makeApplication(profiles: profiles)])
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent("Parallax/library.json")
                    .path
            )
        )
    }

    func testLegacyDecodeIsTypedDeterministicAndAllocatesNoStorageIdentity() throws {
        let fixture = try XCTUnwrap(
            LibraryFixtureCase.matrix.first {
                $0.fileName == "legacy-missing-null-storage-name.json"
            }
        )
        let first = try LibraryPersistence.decodeLibrary(from: fixture.data())
        let second = try LibraryPersistence.decodeLibrary(from: fixture.data())

        XCTAssertEqual(first, second)
        guard case let .migrationRequired(legacy) = first else {
            XCTFail("Expected a typed migration-required result")
            return
        }
        XCTAssertEqual(legacy.format, .versioned(1))
        XCTAssertEqual(
            legacy.applications.flatMap(\.profiles).map(\.storageNameProvenance),
            [.missing, .null]
        )
    }

    @MainActor
    func testBlockerFreeLegacyLibraryMigratesBeforeStoreBecomesWritable() throws {
        let fixture = try XCTUnwrap(
            LibraryFixtureCase.matrix.first { $0.fileName == "valid-v1-library.json" }
        )
        let legacyRoot = temporaryDirectory.appendingPathComponent(
            "LegacyProfiles",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        let fixtureText = try XCTUnwrap(
            String(data: fixture.data(), encoding: .utf8)
        )
        let sourceData = Data(
            fixtureText.replacingOccurrences(
                of: "/FixtureData/ManagedProfiles",
                with: legacyRoot.path
            ).utf8
        )
        let libraryURL = temporaryDirectory
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: libraryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sourceData.write(to: libraryURL)
        let store = makeStore()
        let candidateURL = temporaryDirectory
            .appendingPathComponent("Candidate.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: candidateURL,
            withIntermediateDirectories: true
        )

        XCTAssertNil(store.migrationRequiredLibrary)
        XCTAssertEqual(store.applications.count, 1)
        store.addApplication(at: candidateURL)

        XCTAssertEqual(store.applications.count, 2)
        XCTAssertNotEqual(try Data(contentsOf: libraryURL), sourceData)
        XCTAssertNoThrow(
            try LibraryPersistence.decodeApplications(
                from: Data(contentsOf: libraryURL)
            )
        )
    }

    @MainActor
    func testApplicationUpdateCannotForgeStorageIdentity() {
        let profile = LaunchProfile(name: "Personal")
        let persisted = makeApplication(profiles: [profile])
        let store = makeStore()
        store.applications = [persisted]
        store.selectedApplicationID = persisted.id
        store.selectedProfileID = profile.id
        let forgedProfile = LaunchProfile(
            id: profile.id,
            storageID: UUID(),
            name: profile.name
        )
        let forgedApplication = ManagedApplication(
            id: persisted.id,
            storageID: UUID(),
            displayName: "Renamed",
            appPath: persisted.appPath,
            preset: persisted.preset,
            baseStoragePath: persisted.baseStoragePath,
            profiles: [forgedProfile]
        )

        store.updateApplication(forgedApplication)

        XCTAssertEqual(store.applications.first?.storageID, persisted.storageID)
        XCTAssertEqual(store.applications.first?.profiles.first?.storageID, profile.storageID)
        XCTAssertEqual(store.applications.first?.displayName, "Renamed")
    }

    @MainActor
    func testProfileUpdateCannotForgeStorageIdentity() {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profiles: [profile])
        let store = makeStore()
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id
        let forged = LaunchProfile(
            id: profile.id,
            storageID: UUID(),
            name: "Renamed"
        )

        store.updateProfile(forged)

        XCTAssertEqual(store.selectedProfile?.storageID, profile.storageID)
        XCTAssertEqual(store.selectedProfile?.name, "Renamed")
    }

    @MainActor
    func testExplicitDuplicateGetsFreshLogicalAndStorageIdentity() {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profiles: [profile])
        let store = makeStore()
        store.applications = [application]
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        XCTAssertTrue(store.duplicateSelectedProfile())

        let profiles = store.applications[0].profiles
        XCTAssertEqual(profiles.count, 2)
        XCTAssertNotEqual(profiles[0].id, profiles[1].id)
        XCTAssertNotEqual(profiles[0].storageID, profiles[1].storageID)
    }

    @MainActor
    private func assertDistinctProfilePaths(
        _ firstProfile: LaunchProfile,
        _ secondProfile: LaunchProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let application = makeApplication(
            profiles: [firstProfile, secondProfile]
        )
        let store = makeStore()
        let firstPath = store.profileFolderPath(
            for: application,
            profile: firstProfile
        )
        let secondPath = store.profileFolderPath(
            for: application,
            profile: secondProfile
        )

        XCTAssertNotEqual(
            volumeInsensitiveIdentity(firstPath),
            volumeInsensitiveIdentity(secondPath),
            "Visible profile names must not determine physical storage identity.",
            file: file,
            line: line
        )
    }

    private func makeApplication(
        displayName: String = "Browser",
        appPath: String = "/Applications/Browser.app",
        profiles: [LaunchProfile] = []
    ) -> ManagedApplication {
        ManagedApplication(
            displayName: displayName,
            appPath: appPath,
            preset: .custom,
            baseStoragePath: temporaryDirectory.path,
            profiles: profiles
        )
    }

    @MainActor
    private func makeStore() -> LibraryStore {
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
            ?? .standard
        return LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            launcher: WorkspaceApplicationLauncher(),
            settings: AppSettings(userDefaults: userDefaults)
        )
    }

    private func volumeInsensitiveIdentity(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private func storageID<T: Encodable>(in value: T) throws -> UUID {
        try storageID(in: jsonObject(for: value))
    }

    private func storageID(in object: [String: Any]) throws -> UUID {
        let component = try storageComponent(in: object)
        return try XCTUnwrap(
            UUID(uuidString: component),
            "storageID must contain an opaque UUID-backed component."
        )
    }

    private func storageComponent(in object: [String: Any]) throws -> String {
        try XCTUnwrap(
            object["storageID"] as? String,
            "Every v2 application and profile must encode its immutable storageID."
        )
    }

    private func jsonObject<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func applicationObject(
        id: UUID = UUID(),
        storageID: UUID = UUID(),
        profileObjects: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "storageID": storageID.uuidString,
            "displayName": "Imported Browser",
            "appPath": "/Applications/Imported Browser.app",
            "preset": "custom",
            "profiles": profileObjects
        ]
    }

    private func profileObject(
        id: UUID = UUID(),
        storageID: UUID = UUID()
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "storageID": storageID.uuidString,
            "name": "Imported Profile",
            "argumentsText": "",
            "environmentText": "",
            "notes": ""
        ]
    }

    private func assertLibraryRejected(
        applications: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": LibraryDocument.currentVersion,
                "applications": applications
            ],
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try LibraryPersistence.decodeApplications(from: data),
            "Duplicate imported identities must be rejected before activation.",
            file: file,
            line: line
        )
    }
}
